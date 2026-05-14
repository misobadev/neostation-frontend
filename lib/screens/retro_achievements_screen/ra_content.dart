import 'dart:io';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/services/permission_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:provider/provider.dart';
import '../../providers/retro_achievements_provider.dart';
import '../../widgets/custom_notification.dart';
import '../../responsive.dart';
import '../../repositories/retro_achievements_repository.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/gestures.dart';
import '../../services/game_service.dart' show GamepadNavigationManager;
import '../app_screen.dart' show AppNavigation;
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';

class RAContent extends StatefulWidget {
  const RAContent({super.key});

  @override
  State<RAContent> createState() => _RAContentState();
}

class _RAContentState extends State<RAContent> {
  final TextEditingController _usernameController = TextEditingController();
  final FocusNode _usernameFocus = FocusNode();

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
      onPreviousTab: AppNavigation.previousTab,
      onNextTab: AppNavigation.nextTab,
      onLeftBumper: AppNavigation.previousTab,
      onRightBumper: AppNavigation.nextTab,
    );
    _tvNav!.initialize();
    GamepadNavigationManager.pushLayer(
      'ra_content',
      onActivate: () => _tvNav?.activate(),
      onDeactivate: () => _tvNav?.deactivate(),
    );
  }

  void _tvMove(int delta) {
    if (!_isTelevision || _usernameFocus.hasFocus) return;
    setState(() {
      _tvFieldIndex = (_tvFieldIndex + delta).clamp(0, 1);
    });
  }

  void _tvSelect() {
    if (!_isTelevision) return;
    if (_tvFieldIndex == 0) {
      _usernameFocus.requestFocus();
    } else {
      _connectToRA();
    }
  }

  bool _isTvSelected(int slot) => _isTelevision && _tvFieldIndex == slot;

  Future<void> _connectToRA() async {
    final raProvider = context.read<RetroAchievementsProvider>();
    if (raProvider.isLoading) return;
    final username = _usernameController.text.trim();
    if (username.isNotEmpty) {
      await RetroAchievementsRepository.saveRAUser(username);
    }
    final success = await raProvider.connect(_usernameController.text);
    if (!mounted) return;
    if (success) {
      AppNotification.showNotification(
        context,
        AppLocale.successConnectedRA.getString(context),
        type: NotificationType.success,
      );
    } else if (raProvider.error != null) {
      AppNotification.showNotification(
        context,
        raProvider.error!,
        type: NotificationType.error,
      );
    }
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('ra_content');
    _tvNav?.dispose();
    _usernameController.dispose();
    _usernameFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<RetroAchievementsProvider>(
      builder: (context, raProvider, child) {
        // Trigger fetch achievement of the week if not loaded
        if (!raProvider.gotwLoaded && !raProvider.isLoading) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            raProvider.fetchGOTW();
          });
        }

        return Responsive(
          handheldXS: _buildLandscapeLayout(context, raProvider),
          handheldSmall: _buildLandscapeLayout(context, raProvider),
          handheldMedium: _buildLandscapeLayout(context, raProvider),
          handheldLarge: _buildLandscapeLayout(context, raProvider),
          handheldXL: _buildLandscapeLayout(context, raProvider),
        );
      },
    );
  }

  Widget _buildLandscapeLayout(
    BuildContext context,
    RetroAchievementsProvider raProvider,
  ) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 12.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: 64.r), // Space for header (32.r + margin)
          // Contenido principal
          if (!raProvider.isConnected) ...[
            Center(
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
                        child: _buildLandscapeConnectionForm(
                          context,
                          raProvider,
                        ),
                      ),
                      SizedBox(width: 16.r),
                      SizedBox(width: 300.r, child: _buildInfoBox(context)),
                    ],
                  ),
                ),
              ),
            ),
          ] else ...[
            // First Row: Profile + AOTW
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _buildSteamDashboard(context, raProvider)),
                SizedBox(width: 12.r),
                Expanded(child: _buildGameOfTheWeek(context, raProvider)),
              ],
            ),

            // Second Row: Recently Played + User Awards
            if (raProvider.summaryLoaded) ...[
              SizedBox(height: 12.0.r),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _buildMostRecentGame(context, raProvider)),
                  SizedBox(width: 12.r),
                  Expanded(child: _buildUserAwards(context, raProvider)),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildTvFieldHighlight({
    required int slot,
    required ThemeData theme,
    required Widget child,
  }) {
    if (!_isTvSelected(slot)) return child;
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

  Widget _buildLandscapeConnectionForm(
    BuildContext context,
    RetroAchievementsProvider raProvider,
  ) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.all(16.r),
      decoration: BoxDecoration(
        color: theme.cardColor.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.15),
          width: 1.r,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Header principal con logo y título
          Row(
            children: [
              Expanded(
                child: Text(
                  AppLocale.raLogin.getString(context),
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

          // Username field
          Container(
            constraints: BoxConstraints(maxWidth: 220.r),
            child: _buildTvFieldHighlight(
              slot: 0,
              theme: theme,
              child: SizedBox(
                height: 32.r,
                child: TextFormField(
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
                  style: TextStyle(fontSize: 11.r),
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _connectToRA(),
                ),
              ),
            ),
          ),
          SizedBox(height: 6.r),

          // Connect button
          Container(
            constraints: BoxConstraints(maxWidth: 220.r),
            decoration: _isTvSelected(1)
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
                onPressed: raProvider.isLoading ? null : _connectToRA,
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: theme.colorScheme.onPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8.r),
                  ),
                  elevation: 0,
                ),
                child: raProvider.isLoading
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
                        AppLocale.connect.getString(context),
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

  Widget _buildInfoBox(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.all(16.r),
      decoration: BoxDecoration(
        color: theme.cardColor.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.15),
          width: 1.r,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Symbols.emoji_events_rounded,
                color: theme.colorScheme.primary,
                size: 24.r,
              ),
              SizedBox(width: 12.r),
              Expanded(
                child: Text(
                  AppLocale.raWhatIs.getString(context),
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
            AppLocale.raDescription.getString(context),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
              fontSize: 8.r,
            ),
            softWrap: true,
          ),
          SizedBox(height: 6.r),
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
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                fontSize: 8.r,
              ),
              children: [
                TextSpan(text: AppLocale.raCreateAccountAt.getString(context)),
                TextSpan(
                  text: 'retroachievements.org',
                  style: TextStyle(
                    color: theme.colorScheme.primary,
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

  Widget _buildSteamDashboard(
    BuildContext context,
    RetroAchievementsProvider raProvider,
  ) {
    final user = raProvider.user!;
    final theme = Theme.of(context);

    return Container(
      padding: EdgeInsets.all(12.0.r),
      decoration: BoxDecoration(
        color: theme.cardColor.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12.0.r),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.15),
          width: 1.r,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: USER PROFILE + Logout
          Row(
            children: [
              Icon(Symbols.person_rounded, color: theme.colorScheme.primary, size: 20.r),
              SizedBox(width: 8.r),
              Text(
                AppLocale.userProfile.getString(context),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                  fontSize: 10.r,
                  letterSpacing: 1.2,
                ),
              ),
              const Spacer(),
              // Logout Button in header - Compact
              GestureDetector(
                onTap: () {
                  SfxService().playBackSound();
                  raProvider.disconnect(clearSavedUser: true);
                  _usernameController.clear();
                  AppNotification.showNotification(
                    context,
                    AppLocale.disconnectedRA.getString(context),
                    type: NotificationType.info,
                  );
                },
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Icon(
                    Symbols.logout_rounded,
                    color: theme.colorScheme.error.withValues(alpha: 0.8),
                    size: 16.r,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 10.r),

          // Body: Avatar + Info + Stats
          Row(
            children: [
              // Avatar
              Container(
                width: 48.r,
                height: 48.r,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.3),
                    width: 2.r,
                  ),
                ),
                child: ClipOval(
                  child: user.userPic.isNotEmpty
                      ? Image.network(
                          'https://retroachievements.org${user.userPic}',
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) => Icon(
                            Symbols.account_circle_rounded,
                            size: 32.r,
                            color: theme.colorScheme.primary,
                          ),
                        )
                      : Icon(
                          Symbols.account_circle_rounded,
                          size: 32.r,
                          color: theme.colorScheme.primary,
                        ),
                ),
              ),
              SizedBox(width: 12.r),

              // User details
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            user.user,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              fontSize: 12.r,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        SizedBox(width: 6.r),
                        Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 6.r,
                            vertical: 1.r,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.1,
                            ),
                            borderRadius: BorderRadius.circular(8.r),
                            border: Border.all(
                              color: theme.colorScheme.primary.withValues(
                                alpha: 0.2,
                              ),
                            ),
                          ),
                          child: Text(
                            user.userType.toUpperCase(),
                            style: TextStyle(
                              color: theme.colorScheme.primary,
                              fontSize: 7.r,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    Text(
                      AppLocale.raPlayer.getString(context),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.6,
                        ),
                        fontSize: 9.r,
                      ),
                    ),
                    SizedBox(height: 4.r),
                    Text(
                      user.motto.isNotEmpty
                          ? user.motto
                          : AppLocale.noMottoSet.getString(context),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 9.r,
                        fontStyle: FontStyle.italic,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.5,
                        ),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),

              // Summary Stats on the right
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: 8.r,
                      vertical: 4.r,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8.r),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Symbols.stars_rounded,
                          size: 10.r,
                          color: theme.colorScheme.primary,
                        ),
                        SizedBox(width: 4.r),
                        Text(
                          '${user.totalPoints}',
                          style: TextStyle(
                            color: theme.colorScheme.primary,
                            fontSize: 10.r,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: 4.r),
                  Text(
                    '${user.contribCount} ${AppLocale.contributions.getString(context)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 8.r,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGameOfTheWeek(
    BuildContext context,
    RetroAchievementsProvider raProvider,
  ) {
    final theme = Theme.of(context);
    final gotw = raProvider.gotw;

    return Container(
      padding: EdgeInsets.all(12.0.r),
      decoration: BoxDecoration(
        color: theme.cardColor.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12.0.r),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.15),
          width: 1.r,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Symbols.emoji_events_rounded,
                color: theme.colorScheme.primary,
                size: 20.r,
              ),
              SizedBox(width: 8.r),
              Text(
                AppLocale.aotw.getString(context),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                  fontSize: 10.r,
                  letterSpacing: 1.2,
                ),
              ),
              const Spacer(),
              if (gotw != null)
                Text(
                  '${gotw.totalPlayers} ${AppLocale.players.getString(context)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 9.r,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
            ],
          ),
          SizedBox(height: 10.r),
          if (raProvider.isLoading && !raProvider.gotwLoaded)
            Center(
              child: Padding(
                padding: EdgeInsets.all(20.r),
                child: SizedBox(
                  width: 20.r,
                  height: 20.r,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
            )
          else if (gotw != null)
            Row(
              children: [
                // Badge del logro
                Container(
                  width: 48.r,
                  height: 48.r,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8.r),
                    color: theme.colorScheme.surface,
                    border: Border.all(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.05,
                      ),
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8.r),
                    child: Image.network(
                      'https://media.retroachievements.org${gotw.achievement.badgeUrl}',
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => Icon(
                        Symbols.emoji_events_rounded,
                        color: theme.colorScheme.primary,
                        size: 24.r,
                      ),
                    ),
                  ),
                ),
                SizedBox(width: 12.r),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        gotw.game.title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          fontSize: 12.r,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        gotw.console.title,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.6,
                          ),
                          fontSize: 9.r,
                        ),
                      ),
                      SizedBox(height: 4.r),
                      Text(
                        AppLocale.achievementLabel
                            .getString(context)
                            .replaceFirst('{title}', gotw.achievement.title),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.bold,
                          fontSize: 10.r,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 8.r,
                        vertical: 4.r,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8.r),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Symbols.stars_rounded,
                            size: 10.r,
                            color: theme.colorScheme.primary,
                          ),
                          SizedBox(width: 4.r),
                          Text(
                            '${gotw.achievement.points}',
                            style: TextStyle(
                              color: theme.colorScheme.primary,
                              fontSize: 10.r,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: 4.r),
                    Text(
                      '${gotw.unlocksCount} ${AppLocale.unlocks.getString(context)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 8.r,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            )
          else
            Center(
              child: Text(
                AppLocale.couldNotLoadAOTW.getString(context),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 10.r,
                  color: theme.colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMostRecentGame(
    BuildContext context,
    RetroAchievementsProvider raProvider,
  ) {
    final theme = Theme.of(context);
    final summary = raProvider.userSummary;
    if (summary == null) return const SizedBox.shrink();

    final lastGame = summary.recentlyPlayed.isNotEmpty
        ? summary.recentlyPlayed.first
        : null;

    return Container(
      padding: EdgeInsets.all(12.0.r),
      decoration: BoxDecoration(
        color: theme.cardColor.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12.0.r),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.15),
          width: 1.r,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Icon(Symbols.history_rounded, color: theme.colorScheme.primary, size: 20.r),
              SizedBox(width: 8.r),
              Text(
                AppLocale.recentlyPlayed.getString(context),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                  fontSize: 10.r,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          SizedBox(height: 10.r),

          if (lastGame != null)
            Row(
              children: [
                // Game Icon
                Container(
                  width: 48.r,
                  height: 48.r,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8.r),
                    color: theme.colorScheme.surface,
                    border: Border.all(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.05,
                      ),
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8.r),
                    child: lastGame.imageIcon.isNotEmpty
                        ? Image.network(
                            'https://media.retroachievements.org${lastGame.imageIcon}',
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) => Icon(
                              Symbols.videogame_asset_rounded,
                              color: theme.colorScheme.primary,
                              size: 24.r,
                            ),
                          )
                        : Icon(
                            Symbols.videogame_asset_rounded,
                            color: theme.colorScheme.primary,
                            size: 24.r,
                          ),
                  ),
                ),
                SizedBox(width: 12.r),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        lastGame.title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          fontSize: 12.r,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        lastGame.consoleName,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.6,
                          ),
                          fontSize: 9.r,
                        ),
                      ),
                      if (summary.richPresenceMsg.isNotEmpty)
                        Padding(
                          padding: EdgeInsets.only(top: 4.r),
                          child: Text(
                            summary.richPresenceMsg,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.primary,
                              fontStyle: FontStyle.italic,
                              fontSize: 9.r,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 8.r,
                        vertical: 4.r,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8.r),
                      ),
                      child: Text(
                        '${lastGame.achievementsTotal} ${AppLocale.achivs.getString(context)}',
                        style: TextStyle(
                          color: theme.colorScheme.primary,
                          fontSize: 10.r,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    SizedBox(height: 4.r),
                    Text(
                      AppLocale.lastPlayed.getString(context),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 8.r,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            )
          else
            Center(
              child: Padding(
                padding: EdgeInsets.all(20.r),
                child: Text(
                  AppLocale.noRecentGames.getString(context),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildUserAwards(
    BuildContext context,
    RetroAchievementsProvider raProvider,
  ) {
    final theme = Theme.of(context);
    final awards = raProvider.userAwards;
    if (awards == null || awards.visibleUserAwards.isEmpty) {
      return Container(
        height: 110.r,
        padding: EdgeInsets.all(12.0.r),
        decoration: BoxDecoration(
          color: theme.cardColor.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(12.0.r),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.15),
            width: 1.r,
          ),
        ),
        child: Center(
          child: Text(
            AppLocale.noAwardsYet.getString(context),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ),
      );
    }

    final latestAward = awards.visibleUserAwards.first;

    return Container(
      padding: EdgeInsets.all(12.0.r),
      decoration: BoxDecoration(
        color: theme.cardColor.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12.0.r),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.15),
          width: 1.r,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Icon(
                Symbols.emoji_events_rounded,
                color: theme.colorScheme.primary,
                size: 20.r,
              ),
              SizedBox(width: 8.r),
              Text(
                AppLocale.latestAward.getString(context),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                  fontSize: 10.r,
                  letterSpacing: 1.2,
                ),
              ),
              const Spacer(),
              Text(
                '${awards.totalAwardsCount} ${AppLocale.totalRA.getString(context)}',
                style: TextStyle(
                  color: theme.colorScheme.primary.withValues(alpha: 0.7),
                  fontSize: 8.r,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          SizedBox(height: 10.r),

          Row(
            children: [
              // Award Icon
              Container(
                width: 48.r,
                height: 48.r,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8.r),
                  color: theme.colorScheme.surface,
                  border: Border.all(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.05),
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8.r),
                  child: latestAward.imageIcon.isNotEmpty
                      ? Image.network(
                          'https://media.retroachievements.org${latestAward.imageIcon}',
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) => Icon(
                            Symbols.emoji_events_rounded,
                            color: theme.colorScheme.primary,
                            size: 24.r,
                          ),
                        )
                      : Icon(
                          Symbols.emoji_events_rounded,
                          color: theme.colorScheme.primary,
                          size: 24.r,
                        ),
                ),
              ),
              SizedBox(width: 12.r),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      latestAward.title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        fontSize: 12.r,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${latestAward.consoleName} • ${latestAward.awardType}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.6,
                        ),
                        fontSize: 9.r,
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.only(top: 4.r),
                      child: Text(
                        '${AppLocale.awardedOn.getString(context)} ${_formatAwardDate(latestAward.awardedAt)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontStyle: FontStyle.italic,
                          fontSize: 8.r,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatAwardDate(String dateStr) {
    try {
      final date = DateTime.parse(dateStr);
      return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    } catch (e) {
      return dateStr;
    }
  }
}
