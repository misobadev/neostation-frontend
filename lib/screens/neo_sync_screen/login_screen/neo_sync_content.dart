import 'package:flutter/material.dart';
import 'dart:async';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/widgets/confirm_action_dialog.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/widgets/custom_notification.dart' as custom;
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/widgets/auth_form.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/services/neosync/billing_service.dart';
import 'package:neostation/models/billing_models.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:provider/provider.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:neostation/sync/providers/neo_sync_adapter.dart';
import '../../app_screen.dart';
import 'save_list_view.dart';
import 'neo_sync_shared.dart';
import 'custom_save_folders_view.dart';
import 'plan_selection_view.dart';
import 'neo_sync_dialogs.dart';

/// Active section of the NeoSync tab.
enum NeoSyncSection { dashboard, saveList, customFolders, plans }

/// Main NeoSync content shell.
///
/// Hosts the login flow when signed out and, when signed in, the NeoSync
/// dashboard (header + 3 menu entries) plus the full-screen sub-views (Save
/// list, Custom save folders, Update your plan). Each sub-view manages its own
/// navigation layer; this shell only routes between them.
class NeoSyncContent extends StatefulWidget {
  const NeoSyncContent({super.key});

  @override
  NeoSyncContentState createState() => NeoSyncContentState();
}

class NeoSyncContentState extends State<NeoSyncContent>
    with TickerProviderStateMixin {
  static bool _dataLoadedThisSession = false;
  bool _isInitialLoadInProgress = false;
  NeoSyncSection _section = NeoSyncSection.dashboard;
  late GamepadNavigation _dashboardGamepadNav;
  int _selectedMenuIndex = 0;

  // Variables para billing
  List<PlanInfo> _plans = [];
  static bool _plansLoadedThisSession = false;
  static bool _profileLoaded = false;

  // Billing methods
  Future<void> _loadProfileIfNeeded() async {
    final authService = Provider.of<AuthService>(context, listen: false);
    if (!_profileLoaded ||
        authService.currentUser == null ||
        authService.currentUser!.username.isEmpty) {
      await authService.getProfile();
      _profileLoaded = true;
    }
  }

  Future<void> _loadPlansIfNeeded() async {
    final authService = Provider.of<AuthService>(context, listen: false);
    final billingService = Provider.of<BillingService>(context, listen: false);
    if (!_plansLoadedThisSession || _plans.isEmpty) {
      if (authService.isLoggedIn) {
        final result = await billingService.getAvailablePlans();
        if (mounted) {
          setState(() {
            if (result['success']) {
              _plans = result['plans'];
              const planOrder = ['free', 'micro', 'mini', 'mega', 'ultra'];
              _plans.sort((a, b) {
                final aIndex = planOrder.indexOf(a.name);
                final bIndex = planOrder.indexOf(b.name);
                final aOrder = aIndex == -1 ? planOrder.length : aIndex;
                final bOrder = bIndex == -1 ? planOrder.length : bIndex;
                return aOrder.compareTo(bOrder);
              });
              _plansLoadedThisSession = true;
            }
          });
        }
      }
    }
  }

  Future<void> _upgradePlan(String planName, String billingPeriod) async {
    final authService = Provider.of<AuthService>(context, listen: false);
    final billingService = Provider.of<BillingService>(context, listen: false);

    final user = authService.currentUser;
    if (user == null) {
      custom.AppNotification.showNotification(
        context,
        AppLocale.neoSyncNotConnected.getString(context),
        type: custom.NotificationType.error,
      );
      return;
    }

    final result = await billingService.createCheckoutSession(
      userId: user.id,
      planName: planName,
      billingPeriod: billingPeriod,
      email: user.email,
    );

    if (result['success']) {
      if (result['upgrade'] == true) {
        if (!mounted) return;
        final authService = Provider.of<AuthService>(context, listen: false);
        await authService.getProfile();
        if (mounted) setState(() {});
      } else {
        final session = result['session'] as BillingSession;
        if (await canLaunchUrl(Uri.parse(session.url))) {
          try {
            await launchUrl(
              Uri.parse(session.url),
              mode: LaunchMode.externalApplication,
            );
          } catch (e) {
            if (!mounted) return;
            custom.AppNotification.showNotification(
              context,
              '${AppLocale.error.getString(context)}: ${session.url}',
              type: custom.NotificationType.error,
            );
          }
        } else {
          if (!mounted) return;
          custom.AppNotification.showNotification(
            context,
            '${AppLocale.error.getString(context)}: ${session.url}',
            type: custom.NotificationType.error,
          );
        }
      }
    } else {
      if (!mounted) return;
      custom.AppNotification.showNotification(
        context,
        '${AppLocale.error.getString(context)}: ${result['message']}',
        type: custom.NotificationType.error,
      );
    }
  }

  Future<void> _cancelSubscription() async {
    final authService = Provider.of<AuthService>(context, listen: false);
    final billingService = Provider.of<BillingService>(context, listen: false);

    final user = authService.currentUser;
    if (user == null) {
      custom.AppNotification.showNotification(
        context,
        AppLocale.neoSyncNotConnected.getString(context),
        type: custom.NotificationType.error,
      );
      return;
    }

    final confirmed = await ConfirmActionDialog.show(
      context,
      title: AppLocale.cancelSubscription.getString(context),
      body: AppLocale.cancelSubscriptionConfirm.getString(context),
      confirmLabel: AppLocale.cancelSubscription.getString(context),
      cancelLabel: AppLocale.keepSubscription.getString(context),
      icon: Symbols.cancel_rounded,
    );

    if (confirmed != true) {
      if (mounted) {
        final neoSyncProvider = Provider.of<NeoSyncProvider>(
          context,
          listen: false,
        );
        await authService.getProfile();
        await neoSyncProvider.loadQuota();
        await neoSyncProvider.loadOnlineFiles();
      }
      return;
    }

    final result = await billingService.cancelSubscription(user.id);

    if (result['success']) {
      await authService.getProfile();
      if (mounted) {
        final neoSyncProvider = Provider.of<NeoSyncProvider>(
          context,
          listen: false,
        );
        await neoSyncProvider.loadQuota();
        await neoSyncProvider.loadOnlineFiles();
      }
      if (mounted) {
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (BuildContext context) {
            return SuccessDialog(
              title: AppLocale.cancelSubscription.getString(context),
              message: AppLocale.cancelSubscriptionConfirm.getString(context),
              onClose: () => Navigator.of(context).pop(),
            );
          },
        );
      }
    } else {
      if (mounted) {
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (BuildContext context) {
            return ErrorDialog(
              title: AppLocale.error.getString(context),
              message: result['message'] ?? AppLocale.error.getString(context),
              onClose: () => Navigator.of(context).pop(),
            );
          },
        );
      }
    }
  }

  IconData _getPlanIcon(String planName) => Symbols.storage_rounded;

  void _goToSection(NeoSyncSection section) {
    setState(() => _section = section);
  }

  // ── Dashboard navigation ────────────────────────────────────────────────

  static const List<NeoSyncSection> _menuSections = [
    NeoSyncSection.saveList,
    NeoSyncSection.customFolders,
    NeoSyncSection.plans,
  ];

  void _initializeDashboardGamepad() {
    _dashboardGamepadNav = GamepadNavigation(
      onNavigateUp: (isRepeat) {
        if (_selectedMenuIndex > 0) {
          setState(() => _selectedMenuIndex = _selectedMenuIndex - 1);
        } else {
          setState(() => _selectedMenuIndex = _menuSections.length - 1);
        }
      },
      onNavigateDown: (isRepeat) {
        setState(
          () => _selectedMenuIndex =
              (_selectedMenuIndex + 1) % _menuSections.length,
        );
      },
      onSelectItem: () {
        SfxService().playNavSound();
        _goToSection(_menuSections[_selectedMenuIndex]);
      },
      onPreviousTab: () => AppNavigation.previousTab(),
      onNextTab: () => AppNavigation.nextTab(),
      onFavorite: () {
        // Y button jumps straight to plan management.
        SfxService().playNavSound();
        _goToSection(NeoSyncSection.plans);
      },
      onXButton: () {
        // X button logs out.
        _onLogout();
      },
      onSettings: () {},
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _dashboardGamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'neo_sync_content',
        onActivate: () => _dashboardGamepadNav.activate(),
        onDeactivate: () => _dashboardGamepadNav.deactivate(),
      );
    });
  }

  void _cleanupResources() {
    GamepadNavigationManager.popLayer('neo_sync_content');
    _dashboardGamepadNav.dispose();
  }

  @override
  void initState() {
    super.initState();
    final authService = Provider.of<AuthService>(context, listen: false);
    if (!authService.isLoggedIn) {
      _dataLoadedThisSession = false;
    }
    _loadProfileIfNeeded();
    _loadPlansIfNeeded();
    _initializeDashboardGamepad();
  }

  @override
  void dispose() {
    _cleanupResources();
    super.dispose();
  }

  bool _isInitialLoadScheduled = false;

  Future<void> _loadInitialDataIfNeeded() async {
    final authService = Provider.of<AuthService>(context, listen: false);
    final neoSyncProvider = Provider.of<NeoSyncProvider>(
      context,
      listen: false,
    );

    if (_isInitialLoadInProgress) return;
    if (authService.isLoggedIn && !_dataLoadedThisSession) {
      _isInitialLoadInProgress = true;
      if (mounted) setState(() {});
      try {
        await authService.getProfile();
        await neoSyncProvider.loadQuota();
        await neoSyncProvider.loadOnlineFiles();
        _dataLoadedThisSession = true;
      } finally {
        if (mounted) setState(() => _isInitialLoadInProgress = false);
      }
    }
  }

  void _onLoginSuccess() async {
    final neoSyncProvider = Provider.of<NeoSyncProvider>(
      context,
      listen: false,
    );
    await neoSyncProvider.loadQuota();
    await neoSyncProvider.loadOnlineFiles();
    if (mounted) {
      _goToSection(NeoSyncSection.dashboard);
    }
  }

  Future<void> _onLogout() async {
    final confirmed = await ConfirmActionDialog.show(
      context,
      title: AppLocale.logoutConfirm.getString(context),
      body: AppLocale.neoSyncLogoutConfirmBody.getString(context),
      confirmLabel: AppLocale.logout.getString(context),
      icon: Symbols.logout_rounded,
    );
    if (!confirmed || !mounted) return;

    final authService = Provider.of<AuthService>(context, listen: false);
    authService.logout();
    _profileLoaded = false;
    _goToSection(NeoSyncSection.dashboard);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthService>(
      builder: (context, authService, child) {
        if (authService.isLoggedIn &&
            !_dataLoadedThisSession &&
            !_isInitialLoadInProgress &&
            !_isInitialLoadScheduled) {
          _isInitialLoadScheduled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _isInitialLoadScheduled = false;
            _loadInitialDataIfNeeded();
          });
        }

        if (!authService.isLoggedIn) {
          return Column(
            children: [
              SizedBox(height: 64.r),
              SingleChildScrollView(
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
                        child: AuthForm(onLoginSuccess: _onLoginSuccess),
                      ),
                      SizedBox(width: 16.r),
                      SizedBox(width: 300.r, child: _buildInfoBox(context)),
                    ],
                  ),
                ),
              ),
            ],
          );
        }

        return Scaffold(
          backgroundColor: Colors.transparent,
          body: _buildActiveView(),
        );
      },
    );
  }

  Widget _buildActiveView() {
    switch (_section) {
      case NeoSyncSection.saveList:
        return SaveListView(
          onBack: () => _goToSection(NeoSyncSection.dashboard),
        );
      case NeoSyncSection.customFolders:
        return CustomSaveFoldersView(
          onBack: () => _goToSection(NeoSyncSection.dashboard),
        );
      case NeoSyncSection.plans:
        return PlanSelectionView(
          initialPlans: _plans,
          onUpgrade: _upgradePlan,
          onCancel: _cancelSubscription,
          getPlanIcon: _getPlanIcon,
          onBack: () => _goToSection(NeoSyncSection.dashboard),
        );
      case NeoSyncSection.dashboard:
        return _buildDashboard();
    }
  }

  Widget _buildDashboard() {
    return Padding(
      padding: EdgeInsets.only(top: 52.r, left: 8.r, right: 8.r, bottom: 8.r),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Tells the user when their saves are going somewhere else:
              // save sync has a single owner, so this dashboard otherwise
              // looks fully live while another provider holds it.
              _buildSaveSyncOwnerNotice(),
              // Main row: profile header (left) + menu options (right)
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 240.w, child: _buildDashboardHeader()),
                    SizedBox(width: 12.r),
                    Expanded(child: _buildMenuList()),
                  ],
                ),
              ),
              SizedBox(height: 8.r),
              // Dedicated footer spanning the full dashboard width
              Align(
                alignment: Alignment.centerRight,
                child: NeoSyncLogoutButton(onTap: _onLogout),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Notice shown when another provider (e.g. RomM) owns save sync.
  ///
  /// Only one provider syncs saves at a time ([SyncManager] holds a single
  /// active id), and nothing else on this screen reflects that — the account,
  /// plan and save list all render normally while NeoSync sync is idle.
  ///
  /// Gated on the owner actually being signed in. A provider that holds save
  /// sync while logged out is not handling anything, so naming it would trade
  /// one wrong impression for another.
  Widget _buildSaveSyncOwnerNotice() {
    return Consumer<SyncManager>(
      builder: (context, syncManager, _) {
        if (syncManager.activeProviderId == NeoSyncAdapter.kProviderId) {
          return const SizedBox.shrink();
        }
        final owner = syncManager.active;
        final ownerSignedIn = owner != null && owner.isAuthenticated;
        final theme = Theme.of(context);
        final radii = theme.extension<CornerRadii>() ?? CornerRadii.m();
        // Signed into NeoSync but another provider holds save sync while it is
        // signed out: nothing is syncing, and being signed in here is exactly
        // what makes that hard to guess.
        final text = ownerSignedIn
            ? '${AppLocale.saveSyncHandledBy.getString(context).replaceFirst('{provider}', owner.meta.name)} · '
                  '${AppLocale.saveSyncSingleProvider.getString(context)}'
            : AppLocale.saveSyncNoneActive.getString(context);
        return Padding(
          padding: EdgeInsets.only(bottom: 8.r),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 8.r),
            decoration: BoxDecoration(
              color: theme.colorScheme.tertiary.withValues(alpha: 0.12),
              borderRadius: radii.radiusExternal,
              border: Border.all(
                color: theme.colorScheme.tertiary.withValues(alpha: 0.5),
                width: 1.r,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Symbols.info_rounded,
                  size: 16.r,
                  color: theme.colorScheme.tertiary,
                ),
                SizedBox(width: 8.r),
                Expanded(
                  child: Text(
                    text,
                    style: TextStyle(
                      fontSize: 11.r,
                      color: theme.colorScheme.onSurface,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDashboardHeader() {
    final authService = Provider.of<AuthService>(context);
    final neoSyncProvider = Provider.of<NeoSyncProvider>(context);
    final theme = Theme.of(context);
    final user = authService.currentUser;
    final radii = theme.extension<CornerRadii>() ?? CornerRadii.m();

    return Container(
      padding: EdgeInsets.all(8.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: radii.radiusExternal,
        border: Border.all(color: theme.colorScheme.outline, width: 1.r),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.shadow.withValues(alpha: 0.1),
            blurRadius: 4.r,
            offset: Offset(2.0.r, 2.0.r),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radii.radiusInternal,
        child: Container(
          padding: EdgeInsets.all(10.r),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                theme.colorScheme.primary.withValues(alpha: 0.18),
                theme.colorScheme.primary.withValues(alpha: 0.04),
              ],
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Identity: name + plan ──
              Text(
                AppLocale.helloUser
                    .getString(context)
                    .replaceFirst('{name}', user?.username ?? ''),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 13.r,
                  color: theme.colorScheme.onSurface,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              SizedBox(height: 3.r),
              // Plan badge
              Container(
                padding: EdgeInsets.symmetric(horizontal: 7.r, vertical: 2.r),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondary,
                  borderRadius: BorderRadius.circular(6.r),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Symbols.storage_rounded,
                      size: 9.r,
                      color: theme.colorScheme.onSecondary,
                    ),
                    SizedBox(width: 3.r),
                    Text(
                      '${user?.plan.toUpperCase() ?? ''} ${AppLocale.quota.getString(context).toUpperCase()}',
                      style: TextStyle(
                        color: theme.colorScheme.onSecondary,
                        fontSize: 7.r,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              // Storage bar — right under name + plan
              if (neoSyncProvider.quota != null) ...[
                SizedBox(height: 10.r),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      neoSyncProvider.quota!.usedQuotaFormatted,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.8,
                        ),
                        fontSize: 8.r,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '${neoSyncProvider.quota!.usagePercentage.toStringAsFixed(1)}%',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        fontSize: 8.r,
                        color: neoSyncProvider.quota!.usagePercentage >= 90
                            ? Colors.red.shade400
                            : theme.colorScheme.primary,
                      ),
                    ),
                    Text(
                      neoSyncProvider.quota!.totalQuotaFormatted,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.8,
                        ),
                        fontSize: 8.r,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 4.r),
                Container(
                  height: 8.r,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.5,
                    ),
                    borderRadius: BorderRadius.circular(4.r),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4.r),
                    child: LinearProgressIndicator(
                      value: neoSyncProvider.quota!.usagePercentage / 100,
                      backgroundColor: Colors.transparent,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        neoSyncProvider.quota!.usagePercentage >= 100
                            ? Colors.red.shade400
                            : neoSyncProvider.quota!.usagePercentage >= 90
                            ? Colors.orange.shade400
                            : theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              ],
              // Mini stat cards — one per row
              SizedBox(height: 10.r),
              _buildHeaderStat(
                context,
                icon: Symbols.cloud_rounded,
                label: AppLocale.onlineSaves.getString(context),
                value: '${neoSyncProvider.onlineTotal}',
              ),
              SizedBox(height: 6.r),
              _buildHeaderStat(
                context,
                icon: Symbols.storage_rounded,
                label: AppLocale.storageLabel.getString(context),
                value: neoSyncProvider.quota != null
                    ? '${neoSyncProvider.quota!.usagePercentage.toStringAsFixed(0)}%'
                    : '—',
              ),
              SizedBox(height: 6.r),
              _buildHeaderGameStat(
                context,
                neoSyncProvider.onlineFiles.isEmpty
                    ? null
                    : neoSyncProvider.onlineFiles.first,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderStat(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 5.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(8.r),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.2),
          width: 1.r,
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 12.r, color: theme.colorScheme.primary),
          SizedBox(width: 6.r),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 11.r,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 7.r,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Header stat showing the most recently synced save with its game thumbnail.
  ///
  /// Uses the same CDN game image as the save list (`gameHash` → webp). Falls
  /// back to a generic icon when there is no save or no game hash.
  Widget _buildHeaderGameStat(BuildContext context, NeoSyncFile? lastSave) {
    final theme = Theme.of(context);
    final gameHash = lastSave?.gameHash;
    final hasImage = gameHash != null && gameHash.isNotEmpty;
    final imageUrl = hasImage
        ? 'https://media.neosync.cloud/games/$gameHash.webp'
        : null;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 5.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(8.r),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.2),
          width: 1.r,
        ),
      ),
      child: Row(
        children: [
          // Game thumbnail (28x28) or fallback icon
          ClipRRect(
            borderRadius: BorderRadius.circular(6.r),
            child: Container(
              width: 24.r,
              height: 24.r,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.1),
              ),
              child: imageUrl != null
                  ? Image.network(
                      imageUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) =>
                          _buildHeaderStatIcon(theme),
                      loadingBuilder: (context, child, loadingProgress) {
                        if (loadingProgress == null) return child;
                        return _buildHeaderStatIcon(theme);
                      },
                    )
                  : _buildHeaderStatIcon(theme),
            ),
          ),
          SizedBox(width: 6.r),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  lastSave != null
                      ? lastSave.gameName.isNotEmpty
                            ? lastSave.gameName
                            : lastSave.fileName
                      : '—',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 9.r,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                Text(
                  AppLocale.lastSyncedSave.getString(context),
                  style: TextStyle(
                    fontSize: 7.r,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeaderStatIcon(ThemeData theme) {
    return Center(
      child: Icon(
        Symbols.videogame_asset_rounded,
        size: 12.r,
        color: theme.colorScheme.primary,
      ),
    );
  }

  Widget _buildMenuList() {
    final theme = Theme.of(context);
    final entries = <_MenuEntry>[
      _MenuEntry(
        icon: Symbols.cloud_rounded,
        title: AppLocale.saveListMenu.getString(context),
        subtitle: AppLocale.onlineSaves.getString(context),
      ),
      _MenuEntry(
        icon: Symbols.folder_special_rounded,
        title: AppLocale.customSaveFoldersMenu.getString(context),
        subtitle: AppLocale.customSaveFoldersTitle.getString(context),
      ),
      _MenuEntry(
        icon: Symbols.payment_rounded,
        title: AppLocale.updateYourPlanMenu.getString(context),
        subtitle: AppLocale.manageYourPlan
            .getString(context)
            .replaceFirst('{plan}', ''),
      ),
    ];

    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final isSelected = index == _selectedMenuIndex;
        final radii =
            theme.extension<CornerRadii>()?.radiusExternal ??
            BorderRadius.circular(14.r);

        return Padding(
          padding: EdgeInsets.only(bottom: 6.r),
          child: Material(
            color: isSelected
                ? theme.colorScheme.secondary.withValues(alpha: 0.12)
                : theme.colorScheme.surface,
            borderRadius: radii,
            child: InkWell(
              onTap: () {
                SfxService().playNavSound();
                setState(() => _selectedMenuIndex = index);
                _goToSection(_menuSections[index]);
              },
              borderRadius: radii,
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
                decoration: BoxDecoration(
                  borderRadius: radii,
                  border: Border.all(
                    color: isSelected
                        ? theme.colorScheme.secondary.withValues(alpha: 0.6)
                        : theme.colorScheme.outline,
                    width: isSelected ? 2.r : 1.r,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: EdgeInsets.all(6.r),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8.r),
                      ),
                      child: Icon(
                        entry.icon,
                        color: isSelected
                            ? theme.colorScheme.secondary
                            : theme.colorScheme.primary,
                        size: 18.r,
                      ),
                    ),
                    SizedBox(width: 10.r),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            entry.title,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              fontSize: 12.r,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                          SizedBox(height: 1.r),
                          Text(
                            entry.subtitle,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 9.r,
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.6,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Symbols.chevron_right_rounded,
                      size: 16.r,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildInfoBox(BuildContext context) {
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Symbols.cloud_rounded,
                color: theme.colorScheme.primary,
                size: 24.r,
              ),
              SizedBox(width: 12.r),
              Expanded(
                child: Text(
                  AppLocale.whatIsNeoSync.getString(context),
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
            AppLocale.neoSyncDescription.getString(context),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
              fontSize: 8.r,
            ),
            softWrap: true,
          ),
          SizedBox(height: 6.r),
          _buildInfoItem(
            context,
            Symbols.cloud_upload_rounded,
            AppLocale.neoSyncSavesSync.getString(context),
          ),
          _buildInfoItem(
            context,
            Symbols.devices_rounded,
            AppLocale.crossPlatformDesc.getString(context),
          ),
          _buildInfoItem(
            context,
            Symbols.security_rounded,
            AppLocale.securePrivateDesc.getString(context),
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
                TextSpan(text: AppLocale.learnMoreEcosystem.getString(context)),
                TextSpan(
                  text: 'neosync.cloud',
                  style: TextStyle(
                    color: theme.colorScheme.primary,
                    decoration: TextDecoration.underline,
                  ),
                  recognizer: TapGestureRecognizer()
                    ..onTap = () async {
                      final url = Uri.parse('https://neosync.cloud');
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

  /// One bullet in the info box, matching the RetroAchievements, ScreenScraper
  /// and RomM connect screens: a single wrapping line, self-spaced so the box
  /// does not interleave its own gaps.
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
}

class _MenuEntry {
  final IconData icon;
  final String title;
  final String subtitle;

  const _MenuEntry({
    required this.icon,
    required this.title,
    required this.subtitle,
  });
}
