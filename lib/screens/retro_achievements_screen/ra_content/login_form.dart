part of '../ra_content.dart';

/// The signed-out login card: the username/API-key form, the "what is
/// RetroAchievements" info box, and the connect flow behind them.
///
/// All state lives on the host [State]; this extension only moves the
/// methods out of the monolith — behaviour is unchanged. `setState` calls
/// route through the host [rebuild] bridge (`State.setState` is
/// `@protected` and can't be invoked from an extension).
extension _LoginForm on _RAContentState {
  /// Pre-populates the username field with the last saved user so the form is
  /// not blank after a failed auto-login (e.g. when the device is offline).
  Future<void> _prefillUsername() async {
    final saved = await RetroAchievementsRepository.getRAUser();
    if (!mounted || saved == null || saved.isEmpty) return;
    if (_usernameController.text.isEmpty) {
      _usernameController.text = saved;
    }
  }

  Future<void> _connectToRA() async {
    final raProvider = context.read<RetroAchievementsProvider>();
    if (raProvider.isLoading) return;
    // Same up-front check (and message) as the ScreenScraper login: without it
    // an empty submit round-trips to the API and surfaces a raw connection
    // error instead of telling the user what is missing.
    if (_usernameController.text.trim().isEmpty ||
        _apiKeyController.text.trim().isEmpty) {
      AppNotification.showNotification(
        context,
        AppLocale.pleaseCompleteAllFields.getString(context),
        type: NotificationType.error,
      );
      return;
    }
    final apiKey = _apiKeyController.text.trim();
    final success = await raProvider.connect(
      _usernameController.text,
      apiKey: apiKey,
    );
    if (!mounted) return;
    if (success) {
      // A login that could not be stored still works for this session, so say
      // so rather than reporting a plain success the next launch contradicts.
      AppNotification.showNotification(
        context,
        raProvider.credentialsPersisted
            ? AppLocale.successConnectedRA.getString(context)
            : AppLocale.credentialStorageUnavailable.getString(context),
        type: raProvider.credentialsPersisted
            ? NotificationType.success
            : NotificationType.info,
      );
    } else if (raProvider.error != null) {
      AppNotification.showNotification(
        context,
        raProvider.error!,
        type: NotificationType.error,
      );
    }
  }

  Future<void> _openRaControlPanel() async {
    final url = Uri.parse(
      'https://retroachievements.org/settings?tab=applications',
    );
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  CornerRadii _raRadii(BuildContext context) =>
      Theme.of(context).extension<CornerRadii>() ?? CornerRadii.m();

  /// A field's selection highlight: a solid ring, no glow, as on NeoSync's.
  Widget _buildFieldHighlight({
    required int slot,
    required ThemeData theme,
    required Widget child,
  }) {
    // The ring is the field's own border ([_raInputDecoration] with
    // `selected`): one drawn around this box sat below the field on macOS,
    // where the box is taller than the border.
    return child;
  }

  /// A field sunk into the glass panel, its label kept inside as the
  /// placeholder: floated, it sat on the field's edge under the ring.
  InputDecoration _raInputDecoration(
    ThemeData theme, {
    required String label,
    required String hint,
    Widget? suffixIcon,
    bool selected = false,
  }) {
    final radius = _raRadii(context).radiusInternal;
    return InputDecoration(
      labelText: label,
      floatingLabelBehavior: FloatingLabelBehavior.never,
      labelStyle: TextStyle(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
        fontSize: 11.r,
      ),
      hintText: hint,
      hintStyle: TextStyle(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
        fontSize: 10.r,
      ),
      contentPadding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
      filled: true,
      fillColor: theme.scaffoldBackgroundColor,
      border: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(
          color: selected
              ? theme.colorScheme.onSurface
              : theme.colorScheme.outline.withValues(alpha: 0.15),
          width: selected ? 2.r : 1.r,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(
          color: selected
              ? theme.colorScheme.onSurface
              : theme.colorScheme.primary,
          width: selected ? 2.r : 1.r,
        ),
      ),
      suffixIcon: suffixIcon,
    );
  }

  /// A button as the app's own (GamepadControl), wearing the fields' ring and
  /// the A glyph while the cursor is on it, since A presses it.
  Widget _raButton(
    ThemeData theme, {
    required int slot,
    required String label,
    required VoidCallback? onTap,
    bool primary = false,
    bool busy = false,
  }) {
    final selected = isSelected(slot);
    final button = FittedBox(
      fit: BoxFit.scaleDown,
      child: GamepadControl(
        iconPath: selected ? 'assets/images/gamepad/Xbox_A_button.png' : null,
        label: label,
        onTap: onTap,
        busy: busy,
        backgroundColor: primary
            ? theme.colorScheme.tertiary
            : theme.colorScheme.tertiaryFixed,
        textColor: primary
            ? theme.colorScheme.onTertiary
            : theme.colorScheme.onTertiaryFixed,
      ),
    );
    if (!selected) return button;
    return Container(
      padding: EdgeInsets.all(2.r),
      decoration: BoxDecoration(
        borderRadius: _raRadii(context).radiusInternal,
        border: Border.all(color: theme.colorScheme.onSurface, width: 2.r),
      ),
      child: button,
    );
  }

  /// Signed out: one NeoGlass panel, RetroAchievements introduced on the left
  /// and the login form on the right, as on the NeoSync tab.
  Widget _buildSignedOutPanel(
    BuildContext context,
    RetroAchievementsProvider raProvider,
  ) {
    final theme = Theme.of(context);
    final radii = _raRadii(context);
    final line = theme.colorScheme.outline.withValues(alpha: 0.15);
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16.r, 0, 16.r, 16.r),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 600.r),
          child: NeoGlassRim(
            cornerRadius: radii.radiusExternalRadius,
            child: Container(
              padding: EdgeInsets.all(20.r),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: radii.radiusExternal,
                border: Border.all(color: line),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _buildInfoBox(context)),
                  Container(
                    width: 1,
                    height: 200.r,
                    margin: EdgeInsets.symmetric(horizontal: 20.r),
                    color: line,
                  ),
                  Expanded(
                    child: _buildLandscapeConnectionForm(context, raProvider),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLandscapeConnectionForm(
    BuildContext context,
    RetroAchievementsProvider raProvider,
  ) {
    final theme = Theme.of(context);
    final field = BoxConstraints(maxWidth: 240.r);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            AppLocale.raLogin.getString(context),
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
              fontSize: 14.r,
            ),
          ),
        ),
        SizedBox(height: 12.r),
        ConstrainedBox(
          constraints: field,
          child: _buildFieldHighlight(
            slot: 0,
            theme: theme,
            child: SizedBox(
              height: 38.r,
              child: TextFormField(
                controller: _usernameController,
                focusNode: _usernameFocus,
                decoration: _raInputDecoration(
                  theme,
                  label: AppLocale.username.getString(context),
                  selected: isSelected(0),
                  hint: AppLocale.enterUsername.getString(context),
                ),
                enabled: !raProvider.isLoading,
                style: TextStyle(fontSize: 12.r),
                textInputAction: TextInputAction.next,
                onFieldSubmitted: (_) => _apiKeyFocus.requestFocus(),
              ),
            ),
          ),
        ),
        SizedBox(height: 8.r),
        ConstrainedBox(
          constraints: field,
          child: _buildFieldHighlight(
            slot: 1,
            theme: theme,
            child: SizedBox(
              height: 38.r,
              child: TextFormField(
                controller: _apiKeyController,
                focusNode: _apiKeyFocus,
                obscureText: _obscureApiKey,
                enableSuggestions: false,
                autocorrect: false,
                decoration: _raInputDecoration(
                  theme,
                  label: AppLocale.raApiKey.getString(context),
                  selected: isSelected(1),
                  hint: AppLocale.raEnterApiKey.getString(context),
                  suffixIcon: IconButton(
                    padding: EdgeInsets.zero,
                    icon: Icon(
                      size: 18.r,
                      _obscureApiKey
                          ? Symbols.visibility_rounded
                          : Symbols.visibility_off_rounded,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                    onPressed: () {
                      rebuild(() {
                        _obscureApiKey = !_obscureApiKey;
                      });
                    },
                  ),
                ),
                enabled: !raProvider.isLoading,
                style: TextStyle(fontSize: 12.r),
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _connectToRA(),
              ),
            ),
          ),
        ),
        SizedBox(height: 10.r),
        _raButton(
          theme,
          slot: 2,
          label: AppLocale.login.getString(context),
          onTap: raProvider.isLoading ? null : _connectToRA,
          primary: true,
          busy: raProvider.isLoading,
        ),
        SizedBox(height: 10.r),
        // Where RetroAchievements shows the personal Web API key, so the app
        // never handles a password.
        _raButton(
          theme,
          slot: 3,
          label: AppLocale.raGetApiKey.getString(context),
          onTap: _openRaControlPanel,
        ),
        SizedBox(height: 6.r),
        ConstrainedBox(
          constraints: field,
          child: Text(
            AppLocale.raApiKeyHelp.getString(context),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
              fontSize: 9.r,
            ),
          ),
        ),
      ],
    );
  }

  /// RetroAchievements introduced: its trophy and name, what it is and where
  /// to sign up.
  Widget _buildInfoBox(BuildContext context) {
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onSurface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Image.asset(
              'assets/images/icons/enhance-prize.webp',
              width: 24.r,
              height: 24.r,
              color: ink,
            ),
            SizedBox(width: 10.r),
            Flexible(
              child: Text(
                'RetroAchievements',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: ink,
                  fontSize: 18.r,
                ),
              ),
            ),
          ],
        ),
        SizedBox(height: 14.r),
        Text(
          AppLocale.raDescription.getString(context),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: ink.withValues(alpha: 0.9),
            fontSize: 10.r,
          ),
          softWrap: true,
        ),
        SizedBox(height: 8.r),
        _buildInfoItem(
          context,
          Symbols.star_outline_rounded,
          AppLocale.raEarnPoints.getString(context),
        ),
        _buildInfoItem(
          context,
          Symbols.public_rounded,
          AppLocale.raGlobalLeaderboards.getString(context),
        ),
        _buildInfoItem(
          context,
          Symbols.history_rounded,
          AppLocale.raGameplayHistory.getString(context),
        ),
        SizedBox(height: 6.r),
        RichText(
          softWrap: true,
          text: TextSpan(
            style: theme.textTheme.bodySmall?.copyWith(
              fontStyle: FontStyle.italic,
              color: ink.withValues(alpha: 0.6),
              fontSize: 10.r,
            ),
            children: [
              TextSpan(text: AppLocale.raCreateAccountAt.getString(context)),
              TextSpan(
                text: 'retroachievements.org',
                style: TextStyle(
                  color: ink,
                  decoration: TextDecoration.underline,
                ),
                recognizer: TapGestureRecognizer()
                  ..onTap = () async {
                    final url = Uri.parse('https://retroachievements.org');
                    if (await canLaunchUrl(url)) {
                      await launchUrl(
                        url,
                        mode: LaunchMode.externalApplication,
                      );
                    }
                  },
              ),
              TextSpan(text: AppLocale.raToStartEarning.getString(context)),
            ],
          ),
        ),
      ],
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
            size: 14.r,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
          ),
          SizedBox(width: 8.r),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                fontSize: 10.r,
              ),
              softWrap: true,
            ),
          ),
        ],
      ),
    );
  }
}
