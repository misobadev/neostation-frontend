import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_locale.dart';
import '../../providers/romm_provider.dart';
import '../../providers/sqlite_config_provider.dart';
import '../../services/game_service.dart' show GamepadNavigationManager;
import '../../services/neosync/auth_service.dart';
import '../../sync/providers/neo_sync_adapter.dart';
import '../../sync/providers/romm_provider.dart';
import '../../sync/sync_manager.dart';
import '../../utils/gamepad_nav.dart';
import '../../utils/login_form_selection.dart';
import '../../widgets/custom_notification.dart';
import '../app_screen.dart';

/// Self-contained RomM connect / account panel for the top-level RomM tab.
///
/// When disconnected it shows the server credential form: the server URL, an
/// authentication mode switch (username + password, or a RomM Client API
/// Token), the fields that mode needs, and connect. The URL leads because both
/// modes need it — the switch only changes how you prove who you are, not which
/// server you are proving it to. When connected it shows the server status plus
/// the save-sync toggle, a disconnect action, and — when [onBrowse] is provided
/// — a shortcut back to the library browser. Unlike the old settings panel this
/// widget owns its own gamepad navigation layer so it works as a standalone tab.
class RommConnectContent extends StatefulWidget {
  /// Invoked by the "back to library" action while connected. Null when the
  /// panel is shown as the disconnected landing view (nothing to go back to).
  final VoidCallback? onBrowse;

  /// Where B goes once no field is focused, when that isn't [onBrowse]: the
  /// Saves tab has no library to return to, so it leaves for Systems instead.
  final VoidCallback? onBack;

  const RommConnectContent({super.key, this.onBrowse, this.onBack});

  @override
  State<RommConnectContent> createState() => _RommConnectContentState();
}

class _RommConnectContentState extends State<RommConnectContent>
    with LoginFormSelection<RommConnectContent> {
  final ScrollController _scrollController = ScrollController();
  final List<GlobalKey> _itemKeys = List.generate(5, (_) => GlobalKey());

  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _userController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _apiKeyController = TextEditingController();
  final FocusNode _urlFocus = FocusNode();
  final FocusNode _userFocus = FocusNode();
  final FocusNode _passwordFocus = FocusNode();
  final FocusNode _apiKeyFocus = FocusNode();

  late final GamepadNavigation _gamepadNav;
  bool _busy = false;

  /// Whether the form is collecting a Client API Token instead of a username
  /// and password. Purely a property of the login form — a connection remembers
  /// its own mode in the database.
  bool _useApiKey = false;

  /// The slots the D-pad walks, which change with both the connection state and
  /// the authentication mode: connected it is three action rows and no field at
  /// all, disconnected it is the server URL, the mode switch, that mode's
  /// secret(s), and connect. Read live, so the cursor is clamped into range the
  /// moment any of that changes — including by something other than this
  /// panel's own buttons.
  @override
  List<FocusNode?> get selectionSlots {
    if (context.read<RommProvider>().isConnected) {
      return const [null, null, null];
    }
    return _useApiKey
        ? [_urlFocus, null, _apiKeyFocus, null]
        : [_urlFocus, null, _userFocus, _passwordFocus, null];
  }

  /// Every node the panel owns, not just the ones the current state shows, so
  /// focus tracking survives the switch to the connected view or between the
  /// two authentication modes.
  @override
  List<FocusNode> get ownedFocusNodes => [
    _urlFocus,
    _userFocus,
    _passwordFocus,
    _apiKeyFocus,
  ];

  /// Slot the mode switch sits on: under the server URL, which both modes need,
  /// and above the fields it actually decides. Left/Right pick a half directly
  /// (see [_setAuthMode]); A flips it, for anyone who reaches it that way.
  static const int _authModeSlot = 1;

  @override
  void initState() {
    super.initState();
    attachFocusSelectionListeners();
    _gamepadNav = GamepadNavigation(
      onNavigateUp: _navigateUp,
      onNavigateDown: _navigateDown,
      onNavigateLeft: () => _setAuthMode(useApiKey: false),
      onNavigateRight: () => _setAuthMode(useApiKey: true),
      onSelectItem: _selectCurrent,
      onBack: _handleBack,
      onPreviousTab: AppNavigation.previousTab,
      onNextTab: AppNavigation.nextTab,
      onLeftBumper: AppNavigation.previousTab,
      onRightBumper: AppNavigation.nextTab,
      allowRepeat: false,
      isTextFieldFocused: isAnyFieldFocused,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final provider = context.read<RommProvider>();
      _urlController.text = provider.serverUrl;
      _userController.text = provider.username;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'romm_connect',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('romm_connect');
    _gamepadNav.dispose();
    detachFocusSelectionListeners();
    _scrollController.dispose();
    _urlController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    _apiKeyController.dispose();
    _urlFocus.dispose();
    _userFocus.dispose();
    _passwordFocus.dispose();
    _apiKeyFocus.dispose();
    super.dispose();
  }

  // ── Gamepad navigation ──────────────────────────────────────────────────────

  /// Returns whether the cursor actually moved, so the gamepad handler can
  /// suppress the nav sound when the move was refused.
  bool _navigateUp() => _moveAndScroll(-1);

  bool _navigateDown() => _moveAndScroll(1);

  bool _moveAndScroll(int delta) {
    if (!moveSelection(delta)) return false;
    _scrollToIndex(selectedSlot);
    return true;
  }

  void _selectCurrent() {
    if (context.read<RommProvider>().isConnected) {
      if (isSelected(0)) {
        widget.onBrowse?.call();
      } else if (isSelected(1)) {
        _toggleSaveSync();
      } else if (isSelected(2)) {
        _disconnect();
      }
      return;
    }
    if (isSelected(_authModeSlot)) {
      _toggleAuthMode();
      return;
    }
    if (focusSelectedField()) return;
    _connect();
  }

  /// Flips between the two login modes. Nothing at or above the switch moves,
  /// so the cursor is left where it is; only the rows below are replaced, and
  /// the mixin clamps a cursor that was parked on one of them.
  void _toggleAuthMode() => _applyAuthMode(!_useApiKey);

  /// Picks a mode outright rather than cycling, which is what Left and Right
  /// do while the cursor is on the switch: Left is the left half (password),
  /// Right is the right half (API key). A two-option control reads as a pair of
  /// positions, not a list to step through, so pointing at one should choose it.
  ///
  /// Returns whether anything changed, so the gamepad handler stays silent when
  /// the mode asked for is already the current one — the same "refused moves
  /// make no sound" contract [moveSelection] follows.
  bool _setAuthMode({required bool useApiKey}) {
    if (context.read<RommProvider>().isConnected) return false;
    if (!isSelected(_authModeSlot)) return false;
    if (isAnyFieldFocused()) return false;
    if (_useApiKey == useApiKey) return false;
    _applyAuthMode(useApiKey);
    return true;
  }

  void _applyAuthMode(bool useApiKey) {
    setState(() => _useApiKey = useApiKey);
  }

  /// B leaves a focused field first — that is what it does everywhere else in
  /// the app — and only steps back once nothing is focused.
  void _handleBack() {
    if (isAnyFieldFocused()) {
      exitTextEntry();
      return;
    }
    (widget.onBack ?? widget.onBrowse)?.call();
  }

  void _scrollToIndex(int index) {
    if (index < 0 || index >= _itemKeys.length) return;
    final ctx = _itemKeys[index].currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      alignment: 0.5,
    );
  }

  // ── Actions ─────────────────────────────────────────────────────────────────

  bool _validateInputs() {
    final urlMissing = _urlController.text.trim().isEmpty;
    final secretMissing = _useApiKey
        ? _apiKeyController.text.trim().isEmpty
        : _userController.text.trim().isEmpty ||
              _passwordController.text.isEmpty;
    if (urlMissing || secretMissing) {
      AppNotification.showNotification(
        context,
        (_useApiKey
                ? AppLocale.rommApiKeyRequired
                : AppLocale.rommCredentialsRequired)
            .getString(context),
        type: NotificationType.error,
      );
      return false;
    }
    return true;
  }

  Future<void> _connect() async {
    if (_busy || !_validateInputs()) return;
    setState(() => _busy = true);
    final provider = context.read<RommProvider>();
    // Both captured before the await: the context can't be read across the gap.
    final neoSyncLoggedIn = context.read<AuthService>().isLoggedIn;
    final persist = context
        .read<SqliteConfigProvider>()
        .updateActiveSyncProvider;
    final error = await provider.connect(
      serverUrl: _urlController.text.trim(),
      username: _useApiKey ? '' : _userController.text.trim(),
      password: _useApiKey ? '' : _passwordController.text,
      apiKey: _useApiKey ? _apiKeyController.text.trim() : '',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (error != null) {
      AppNotification.showNotification(
        context,
        error,
        type: NotificationType.error,
      );
    } else {
      // Adopt save sync only when NeoSync isn't signed in. Save sync is one
      // provider at a time, so switching unconditionally would quietly move it
      // off a NeoSync account the user is still using — the same silent stop
      // _disconnect() guards against in the other direction. With NeoSync
      // logged out there is nothing to take away, and leaving it pointed there
      // means a freshly connected server syncs nowhere at all.
      if (!neoSyncLoggedIn && !_isSaveSyncActive) {
        await SyncManager.instance.setActive(
          RomMSyncProvider.kProviderId,
          persist: persist,
        );
      }
      if (!mounted) return;
      _clearSecretFields();
      // Reset selection so the connected view starts on the first row.
      resetSelection();
      AppNotification.showNotification(
        context,
        AppLocale.rommConnectionSuccess.getString(context),
        type: NotificationType.success,
      );
    }
  }

  Future<void> _disconnect() async {
    final provider = context.read<RommProvider>();
    // Capture before the await: the context can't be read across the gap.
    final persist = context
        .read<SqliteConfigProvider>()
        .updateActiveSyncProvider;
    await provider.disconnect();
    // If RomM was the active save-sync provider, hand save sync back to
    // NeoSync. Leaving "romm" active against a server we just forgot would
    // silently stop ALL save sync — RomM errors out, NeoSync sits idle —
    // until the user thought to re-toggle it.
    await SyncManager.instance.releaseIfActive(
      RomMSyncProvider.kProviderId,
      persist: persist,
    );
    if (!mounted) return;
    _clearSecretFields();
    resetSelection();
  }

  /// Wipes both modes' secrets out of the form once they have been handed to
  /// the provider (or thrown away by a disconnect), so neither lingers on
  /// screen — nor in memory — while the panel stays mounted.
  void _clearSecretFields() {
    _passwordController.clear();
    _apiKeyController.clear();
  }

  bool get _isSaveSyncActive =>
      SyncManager.instance.activeProviderId == RomMSyncProvider.kProviderId;

  /// Toggles whether RomM is the active save-sync provider (vs NeoSync).
  Future<void> _toggleSaveSync() async {
    final persist = context
        .read<SqliteConfigProvider>()
        .updateActiveSyncProvider;
    final target = _isSaveSyncActive
        ? NeoSyncAdapter.kProviderId
        : RomMSyncProvider.kProviderId;
    await SyncManager.instance.setActive(target, persist: persist);
    if (!mounted) return;
    setState(() {});
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<RommProvider>();

    // Match the ScreenScraper / RetroAchievements login layout: a top-anchored,
    // horizontally-scrollable row with the credential card on the left and an
    // explanatory info box on the right (info box shown only when disconnected).
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 12.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: 64.r), // Space for the top navigation dock.
          Center(
            child: SingleChildScrollView(
              controller: _scrollController,
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16.r),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      constraints: BoxConstraints(maxWidth: 260.r),
                      child: _buildFormCard(theme, provider),
                    ),
                    if (!provider.isConnected) ...[
                      SizedBox(width: 16.r),
                      SizedBox(width: 300.r, child: _buildInfoBox(theme)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFormCard(ThemeData theme, RommProvider provider) {
    final connected = provider.isConnected;
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
          Row(
            children: [
              Expanded(
                child: Text(
                  (connected ? AppLocale.rommLibrary : AppLocale.rommLogin)
                      .getString(context),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                    fontSize: 14.r,
                  ),
                ),
              ),
            ],
          ),
          // The status line is redundant on the login form (you are visibly
          // disconnected); show it only once connected, mirroring the peers.
          if (connected) ...[
            SizedBox(height: 8.r),
            _buildStatusLine(theme, provider),
          ],
          SizedBox(height: 12.r),
          if (connected)
            ..._buildConnectedRows(theme)
          else
            ..._buildCredentialRows(theme),
        ],
      ),
    );
  }

  Widget _buildInfoBox(ThemeData theme) {
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
              SvgPicture.asset(
                'assets/images/icons/romm-light.svg',
                width: 24.r,
                height: 24.r,
                colorFilter: ColorFilter.mode(
                  theme.colorScheme.primary,
                  BlendMode.srcIn,
                ),
                fit: BoxFit.contain,
              ),
              SizedBox(width: 12.r),
              Expanded(
                child: Text(
                  AppLocale.rommWhatIs.getString(context),
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
            AppLocale.rommDescription.getString(context),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
              fontSize: 8.r,
            ),
            softWrap: true,
          ),
          SizedBox(height: 6.r),
          _buildInfoItem(
            theme,
            Symbols.grid_view_rounded,
            AppLocale.rommInfoBrowse.getString(context),
          ),
          _buildInfoItem(
            theme,
            Symbols.cloud_sync_rounded,
            AppLocale.rommInfoSaveSync.getString(context),
          ),
          _buildInfoItem(
            theme,
            Symbols.dns_rounded,
            AppLocale.rommInfoSelfHosted.getString(context),
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
                TextSpan(text: AppLocale.rommLearnMoreAt.getString(context)),
                TextSpan(
                  text: 'romm.app',
                  style: TextStyle(
                    color: theme.colorScheme.primary,
                    decoration: TextDecoration.underline,
                  ),
                  recognizer: TapGestureRecognizer()
                    ..onTap = () async {
                      final url = Uri.parse('https://romm.app');
                      if (await canLaunchUrl(url)) {
                        await launchUrl(
                          url,
                          mode: LaunchMode.externalApplication,
                        );
                      }
                    },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoItem(ThemeData theme, IconData icon, String text) {
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

  Widget _buildStatusLine(ThemeData theme, RommProvider provider) {
    final connected = provider.isConnected;
    final String text;
    if (connected) {
      text = AppLocale.rommConnectedAs
          .getString(context)
          .replaceAll('{user}', provider.username);
    } else if (provider.status == RommConnectionStatus.connecting) {
      text = AppLocale.rommConnecting.getString(context);
    } else {
      text = AppLocale.rommStatusDisconnected.getString(context);
    }
    return Row(
      children: [
        Icon(
          connected ? Symbols.cloud_done_rounded : Symbols.cloud_off_rounded,
          size: 16.r,
          color: connected
              ? Colors.greenAccent
              : theme.colorScheme.onSurface.withValues(alpha: 0.5),
        ),
        SizedBox(width: 8.r),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 11.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildCredentialRows(ThemeData theme) {
    return [
      _buildFieldRow(
        theme,
        index: 0,
        label: AppLocale.rommServerUrl.getString(context),
        hint: AppLocale.rommServerUrlHint.getString(context),
        controller: _urlController,
        focusNode: _urlFocus,
      ),
      SizedBox(height: 10.r),
      _buildAuthModeRow(theme),
      SizedBox(height: 10.r),
      if (_useApiKey) ...[
        _buildFieldRow(
          theme,
          index: 2,
          label: AppLocale.rommApiKey.getString(context),
          hint: AppLocale.rommApiKeyHint.getString(context),
          controller: _apiKeyController,
          focusNode: _apiKeyFocus,
          obscure: true,
        ),
      ] else ...[
        _buildFieldRow(
          theme,
          index: 2,
          label: AppLocale.username.getString(context),
          hint: AppLocale.enterUsername.getString(context),
          controller: _userController,
          focusNode: _userFocus,
        ),
        SizedBox(height: 8.r),
        _buildFieldRow(
          theme,
          index: 3,
          label: AppLocale.password.getString(context),
          hint: AppLocale.enterPassword.getString(context),
          controller: _passwordController,
          focusNode: _passwordFocus,
          obscure: true,
        ),
      ],
      SizedBox(height: 12.r),
      _buildConnectButton(theme),
    ];
  }

  /// Two-option switch choosing how to authenticate. A (or a tap on either
  /// half) flips it, so the gamepad needs one slot rather than two.
  Widget _buildAuthModeRow(ThemeData theme) {
    final selected = isSelected(_authModeSlot);
    final scheme = theme.colorScheme;
    // A border participates in layout, so thickening it on selection would grow
    // this row and shove every field below it down — 6px on an AYN Thor, which
    // reads as the form twitching as the cursor passes through. The fields
    // opposite don't do that because their border sits inside a fixed-height
    // box; here the padding gives back exactly what the border takes, so the
    // row occupies the same space selected or not.
    final borderWidth = selected ? 2.r : 1.r;
    return Container(
      key: _itemKeys[_authModeSlot],
      constraints: BoxConstraints(maxWidth: 220.r),
      padding: EdgeInsets.all(4.r - borderWidth),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8.r),
        border: Border.all(
          color: selected
              ? scheme.primary
              : scheme.primary.withValues(alpha: 0.1),
          width: borderWidth,
        ),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.35),
                  blurRadius: 6.r,
                  spreadRadius: 1.r,
                ),
              ]
            : null,
      ),
      child: Row(
        children: [
          _buildAuthModeOption(
            theme,
            label: AppLocale.rommAuthPassword.getString(context),
            active: !_useApiKey,
          ),
          _buildAuthModeOption(
            theme,
            label: AppLocale.rommAuthApiKey.getString(context),
            active: _useApiKey,
          ),
        ],
      ),
    );
  }

  Widget _buildAuthModeOption(
    ThemeData theme, {
    required String label,
    required bool active,
  }) {
    final scheme = theme.colorScheme;
    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          // Either half flips the switch: tapping the half already active is a
          // no-op the user never notices, and this keeps the hit targets even.
          onTap: _busy ? null : _toggleAuthMode,
          borderRadius: BorderRadius.circular(6.r),
          child: Container(
            padding: EdgeInsets.symmetric(vertical: 6.r),
            decoration: BoxDecoration(
              color: active ? scheme.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(6.r),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 9.r,
                fontWeight: active ? FontWeight.bold : FontWeight.normal,
                color: active
                    ? scheme.onPrimary
                    : scheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildConnectedRows(ThemeData theme) {
    return [
      _buildActionRow(
        theme,
        index: 0,
        icon: Symbols.grid_view_rounded,
        label: AppLocale.rommBrowseLibrary.getString(context),
        primary: true,
        onTap: () => widget.onBrowse?.call(),
      ),
      SizedBox(height: 10.r),
      _buildActionRow(
        theme,
        index: 1,
        icon: Symbols.cloud_sync_rounded,
        label: AppLocale.rommUseForSaveSync.getString(context),
        primary: _isSaveSyncActive,
        toggleValue: _isSaveSyncActive,
        onTap: _toggleSaveSync,
      ),
      _buildSaveSyncCaption(theme),
      SizedBox(height: 10.r),
      _buildActionRow(
        theme,
        index: 2,
        icon: Symbols.logout_rounded,
        label: AppLocale.rommDisconnect.getString(context),
        onTap: _disconnect,
      ),
    ];
  }

  /// Caption under the save-sync toggle naming who currently owns save sync.
  ///
  /// Connecting a RomM server does not take save sync off a NeoSync account
  /// that is still signed in (see [_connect]), so a connected server plus
  /// downloads plus playtime can all look healthy while saves go elsewhere.
  /// Not focusable — it is a label for the row above it.
  Widget _buildSaveSyncCaption(ThemeData theme) {
    final scheme = theme.colorScheme;
    final owner = SyncManager.instance.active;
    // Same rule as the library header: a provider that owns save sync while
    // signed out is not handling it, so report that nothing is rather than
    // name it.
    final ownerSignedIn = owner != null && owner.isAuthenticated;
    final String text;
    if (_isSaveSyncActive) {
      text = AppLocale.rommSaveSyncActive.getString(context);
    } else if (!ownerSignedIn) {
      text = AppLocale.saveSyncNoneActive.getString(context);
    } else {
      text =
          '${AppLocale.saveSyncHandledBy.getString(context).replaceFirst('{provider}', owner.meta.name)} · '
          '${AppLocale.saveSyncSingleProvider.getString(context)}';
    }
    return Padding(
      padding: EdgeInsets.only(top: 4.r, left: 12.r, right: 12.r),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9.r,
          color: scheme.onSurface.withValues(alpha: 0.7),
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildFieldRow(
    ThemeData theme, {
    required int index,
    required String label,
    required String hint,
    required TextEditingController controller,
    required FocusNode focusNode,
    bool obscure = false,
  }) {
    final selected = isSelected(index);
    // Mirror the ScreenScraper / RetroAchievements field: a filled input with
    // the label floating inside it, constrained to 220.r, plus a soft primary
    // glow when the gamepad cursor is on this row.
    return Container(
      key: _itemKeys[index],
      constraints: BoxConstraints(maxWidth: 220.r),
      decoration: selected
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(8.r),
              boxShadow: [
                BoxShadow(
                  color: theme.colorScheme.primary.withValues(alpha: 0.35),
                  blurRadius: 6.r,
                  spreadRadius: 1.r,
                ),
              ],
            )
          : null,
      child: SizedBox(
        height: 32.r,
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          obscureText: obscure,
          enabled: !_busy,
          style: TextStyle(fontSize: 11.r),
          decoration: InputDecoration(
            labelText: label,
            labelStyle: TextStyle(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              fontSize: 10.r,
            ),
            floatingLabelStyle: TextStyle(
              color: theme.colorScheme.primary,
              fontSize: 10.r,
              fontWeight: FontWeight.bold,
            ),
            hintText: hint,
            hintStyle: TextStyle(
              fontSize: 10.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
            ),
            filled: true,
            fillColor: theme.colorScheme.onSurface.withValues(alpha: 0.05),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8.r),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8.r),
              borderSide: BorderSide(
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.primary.withValues(alpha: 0.1),
                width: selected ? 2.r : 1.r,
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
        ),
      ),
    );
  }

  /// Primary "Save & Connect" button, matching the RetroAchievements connect
  /// button (full-width elevated button with a gamepad-selection glow).
  Widget _buildConnectButton(ThemeData theme) {
    // Last slot either way, and which number that is depends on the mode.
    final index = submitSlot;
    final selected = isSelected(index);
    return Container(
      key: _itemKeys[index],
      constraints: BoxConstraints(maxWidth: 320.r),
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
          onPressed: _busy ? null : _connect,
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.colorScheme.primary,
            foregroundColor: theme.colorScheme.onPrimary,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8.r),
            ),
            elevation: 0,
            padding: EdgeInsets.zero,
          ),
          child: _busy
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
                  // Same label the RetroAchievements and ScreenScraper login
                  // buttons use, so the three forms read as one family.
                  AppLocale.login.getString(context),
                  style: TextStyle(fontSize: 14.r, fontWeight: FontWeight.bold),
                ),
        ),
      ),
    );
  }

  Widget _buildActionRow(
    ThemeData theme, {
    required int index,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool primary = false,
    bool? toggleValue,
  }) {
    final selected = isSelected(index);
    final scheme = theme.colorScheme;
    final borderColor = selected ? scheme.primary : scheme.outline;
    final bgColor = primary
        ? scheme.primary.withValues(alpha: selected ? 0.22 : 0.12)
        : scheme.onSurface.withValues(alpha: selected ? 0.10 : 0.04);
    return Container(
      key: _itemKeys[index],
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _busy ? null : onTap,
          borderRadius: BorderRadius.circular(8.r),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 12.r),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(8.r),
              border: Border.all(
                color: borderColor,
                width: selected ? 2.r : 1.r,
              ),
            ),
            child: Row(
              children: [
                Icon(icon, size: 18.r, color: scheme.primary),
                SizedBox(width: 10.r),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.r,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
                if (_busy) ...[
                  SizedBox(width: 10.r),
                  SizedBox(
                    width: 12.r,
                    height: 12.r,
                    child: CircularProgressIndicator(strokeWidth: 2.r),
                  ),
                ],
                if (toggleValue != null) ...[
                  const Spacer(),
                  Switch(
                    value: toggleValue,
                    onChanged: _busy ? null : (_) => onTap(),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
