import 'package:flutter/material.dart';

import 'dart:async';

import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/screens/saves_screen/kept_copies_view.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/widgets/confirm_action_dialog.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/widgets/custom_notification.dart' as custom;
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/widgets/auth_form.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/services/neosync/billing_service.dart';
import 'package:neostation/models/billing_models.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:provider/provider.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/utils/neosync_failure_message.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/widgets/neo_glass.dart';
import 'package:neostation/widgets/neosync_logo.dart';
import 'package:neostation/widgets/plan_change_notice.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:neostation/sync/providers/neo_sync_adapter.dart';

import '../../app_screen.dart';
import 'save_list_view.dart';
import 'custom_save_folders_view.dart';
import 'plan_selection_view.dart';
import 'neo_sync_dialogs.dart';

/// Active section of the NeoSync tab.
enum NeoSyncSection { dashboard, saveList, keptCopies, customFolders, plans }

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
  late GamepadNavigation _dashboardGamepadNav;
  int _selectedMenuIndex = 0;

  /// The cursor is on Logout, past the last menu section.
  bool get _logoutSelected => _selectedMenuIndex == _menuSections.length;

  /// The section on show in the panel beside the sidebar: the one the menu
  /// cursor is on (Logout keeps the last).
  NeoSyncSection _shownSection = NeoSyncSection.saveList;

  /// Whether the D-pad drives the panel's section rather than the menu.
  bool _panelFocused = false;

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
    // Another change is still out; the plans view shows it running.
    if (result['busy'] == true) return;

    if (result['success']) {
      if (result['upgrade'] == true) {
        // Changed in place, with no checkout. NeoSync's own message is
        // English, so the reloaded plan is announced in the app language.
        final previousPlan = user.plan;
        await authService.getProfile();
        if (!mounted) return;
        setState(() {});
        final newPlan = authService.currentUser?.plan;
        if (newPlan != null) {
          PlanChangeNotice.show(
            context,
            account: user.id,
            from: previousPlan,
            to: newPlan,
          );
        }
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
      final unconfirmed = result['outcomeUnknown'] == true;
      if (unconfirmed) {
        // The upgrade may have gone through: show the plan NeoSync now has
        // before saying so, so the user checks the right one.
        await authService.getProfile();
      }
      if (!mounted) return;
      final message = neoSyncFailureMessage(
        result,
        (key) => key.getString(context),
      );
      // Not reported as an error: it may well have worked.
      custom.AppNotification.showNotification(
        context,
        unconfirmed
            ? message!
            : '${AppLocale.error.getString(context)}: $message',
        type: unconfirmed
            ? custom.NotificationType.info
            : custom.NotificationType.error,
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

    // Kept: nothing changed, so nothing needs reloading.
    if (confirmed != true) return;

    final result = await billingService.cancelSubscription(user.id);
    // Another change is still out; the plans view shows it running.
    if (result['busy'] == true) return;

    // A cancellation NeoSync didn't confirm may have gone through, so the
    // account is reloaded as for one that did before the user is told.
    var cancelled = result['success'] == true;
    if (cancelled || result['outcomeUnknown'] == true) {
      final reload = await authService.getProfile();
      // NeoSync marks a cancelled subscription "canceling" until its period
      // ends, so the reloaded account shows whether it went through. Only a
      // reload that worked counts: the account held from before may be out
      // of date.
      if (reload['success'] == true &&
          authService.currentUser?.stripeSubscriptionStatus == 'canceling') {
        cancelled = true;
      }
      if (mounted) {
        final neoSyncProvider = Provider.of<NeoSyncProvider>(
          context,
          listen: false,
        );
        await neoSyncProvider.loadQuota();
        await neoSyncProvider.loadOnlineFiles();
      }
    }

    if (cancelled) {
      if (mounted) {
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (BuildContext context) {
            return SuccessDialog(
              title: AppLocale.cancelSubscription.getString(context),
              message: AppLocale.subscriptionCancelledKeepPlan.getString(
                context,
              ),
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
              // Not "Error" when it may well have worked.
              title:
                  (result['outcomeUnknown'] == true
                          ? AppLocale.cancelSubscription
                          : AppLocale.error)
                      .getString(context),
              message: neoSyncFailureMessage(
                result,
                (key) => key.getString(context),
                fallback: AppLocale.error.getString(context),
              )!,
              onClose: () => Navigator.of(context).pop(),
            );
          },
        );
      }
    }
  }

  IconData _getPlanIcon(String planName) => Symbols.storage_rounded;

  /// [NeoSyncSection.dashboard] hands the D-pad back to the menu; any other
  /// section is shown in the panel and given the D-pad.
  void _goToSection(NeoSyncSection section) {
    if (section == NeoSyncSection.dashboard) {
      _backToMenu();
      return;
    }
    setState(() {
      _shownSection = section;
      _selectedMenuIndex = _menuSections.indexOf(section);
    });
    _afterSectionBuilt(_focusPanel);
  }

  /// Runs [action] once a newly shown section has pushed its own gamepad
  /// layer (beneath the menu's), which it does after its first frame.
  void _afterSectionBuilt(VoidCallback action) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) action();
      });
    });
  }

  void _pushMenuLayer() {
    GamepadNavigationManager.pushLayer(
      'neo_sync_content',
      onActivate: () {
        _dashboardGamepadNav.activate();
        if (_panelFocused && mounted) setState(() => _panelFocused = false);
      },
      onDeactivate: () => _dashboardGamepadNav.deactivate(),
    );
  }

  /// → or A on a section: the panel takes the D-pad (the section's own layer,
  /// under the menu's, becomes the active one).
  void _focusPanel() {
    if (!mounted) return;
    setState(() => _panelFocused = true);
    GamepadNavigationManager.popLayer('neo_sync_content');
  }

  /// B in a section: back to the menu, the section still on show.
  void _backToMenu() {
    // A field the section left focused (its search) would keep the keys.
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _panelFocused = false;
    });
    GamepadNavigationManager.popLayer('neo_sync_content');
    _pushMenuLayer();
  }

  /// The menu cursor moved: show its section in the panel, keep the D-pad.
  void _moveMenu(int delta) {
    final stops = _menuSections.length + 1;
    setState(() {
      _selectedMenuIndex = (_selectedMenuIndex + delta + stops) % stops;
      if (!_logoutSelected) {
        _shownSection = _menuSections[_selectedMenuIndex];
      }
    });
  }

  // ── Dashboard navigation ────────────────────────────────────────────────

  static const List<NeoSyncSection> _menuSections = [
    NeoSyncSection.saveList,
    NeoSyncSection.keptCopies,
    NeoSyncSection.customFolders,
    NeoSyncSection.plans,
  ];

  void _initializeDashboardGamepad() {
    _dashboardGamepadNav = GamepadNavigation(
      // The menu's stops are its sections and, last, Logout at the foot of
      // the sidebar (index == the section count).
      onNavigateUp: (isRepeat) => _moveMenu(-1),
      onNavigateDown: (isRepeat) => _moveMenu(1),
      onNavigateRight: (isRepeat) {
        if (_logoutSelected) return;
        SfxService().playNavSound();
        _focusPanel();
      },
      onSelectItem: () {
        SfxService().playNavSound();
        if (_logoutSelected) {
          _onLogout();
          return;
        }
        _focusPanel();
      },
      onPreviousTab: () => AppNavigation.previousTab(),
      onNextTab: () => AppNavigation.nextTab(),
      onFavorite: () {
        // Y button jumps straight to plan management.
        SfxService().playNavSound();
        _goToSection(NeoSyncSection.plans);
      },
      onXButton: () {
        // X is a shortcut to Logout, which also sits at the sidebar's foot.
        _onLogout();
      },
      onSettings: () {},
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _dashboardGamepadNav.initialize();
      // The section on show pushes its layer beneath this one (it is
      // embedded), so the menu has the D-pad from the start.
      _pushMenuLayer();
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
          return _buildSignedOutLayout(context);
        }

        return Scaffold(
          backgroundColor: Colors.transparent,
          body: _buildActiveView(),
        );
      },
    );
  }

  Widget _buildActiveView() => _buildDashboard();

  /// The section on show in the panel, laid out to fit beside the sidebar.
  Widget _buildSectionPanel() {
    void back() => _goToSection(NeoSyncSection.dashboard);
    return switch (_shownSection) {
      NeoSyncSection.keptCopies => KeptCopiesView(
        key: const ValueKey('kept-copies'),
        embedded: true,
        onBack: back,
      ),
      NeoSyncSection.customFolders => CustomSaveFoldersView(
        key: const ValueKey('custom-folders'),
        embedded: true,
        onBack: back,
      ),
      NeoSyncSection.plans => PlanSelectionView(
        key: const ValueKey('plans'),
        embedded: true,
        initialPlans: _plans,
        onUpgrade: _upgradePlan,
        onCancel: _cancelSubscription,
        getPlanIcon: _getPlanIcon,
        onBack: back,
      ),
      _ => SaveListView(
        key: const ValueKey('save-list'),
        embedded: true,
        onBack: back,
      ),
    };
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
                    SizedBox(width: 190.r, child: _buildDashboardHeader()),
                    SizedBox(width: 12.r),
                    // The section the menu is on, as RetroAchievements shows
                    // its sections beside its sidebar.
                    Expanded(child: _buildSectionPanel()),
                  ],
                ),
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

    return NeoGlassRim(
      cornerRadius: radii.radiusExternalRadius,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 12.r),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: radii.radiusExternal,
          border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.15),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Identity: name + plan ──
            Row(
              children: [
                // NeoSync's isotype, in the theme's colour.
                NeoSyncLogo.isotype(height: 16.r),
                SizedBox(width: 8.r),
                Expanded(
                  child: Text(
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
                ),
              ],
            ),
            SizedBox(height: 3.r),
            // Plan + online save count.
            Wrap(
              spacing: 4.r,
              runSpacing: 3.r,
              children: [
                _buildDashboardPill(
                  theme,
                  icon: Symbols.storage_rounded,
                  label:
                      '${user?.plan.toUpperCase() ?? ''} ${AppLocale.quota.getString(context).toUpperCase()}',
                  background: theme.colorScheme.secondary,
                  foreground: theme.colorScheme.onSecondary,
                ),
                // Cancelled, but still on the plan until the period ends.
                // NeoSync's end date is only an estimate, so none is shown.
                if (user?.stripeSubscriptionStatus == 'canceling')
                  _buildDashboardPill(
                    theme,
                    icon: Symbols.schedule_rounded,
                    label: AppLocale.subscriptionEnding
                        .getString(context)
                        .toUpperCase(),
                    background: theme.colorScheme.tertiary,
                    foreground: theme.colorScheme.onTertiary,
                  ),
                // No count until a listing has worked: a failed or first
                // load has counted nothing.
                if (!neoSyncProvider.onlineFilesLoadFailed &&
                    !(neoSyncProvider.isLoadingOnlineFiles &&
                        neoSyncProvider.onlineFiles.isEmpty))
                  _buildDashboardPill(
                    theme,
                    icon: Symbols.cloud_rounded,
                    label:
                        '${neoSyncProvider.onlineTotal} ${AppLocale.onlineSaves.getString(context).toUpperCase()}',
                    background: theme.colorScheme.primary.withValues(
                      alpha: 0.12,
                    ),
                    foreground: theme.colorScheme.onSurface,
                    border: theme.colorScheme.primary.withValues(alpha: 0.25),
                  ),
              ],
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
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
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
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
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
            // The RetroAchievements sidebar's format: the account above a
            // line, then the menu and Logout at the foot. Only the menu
            // scrolls, on a screen too short for it.
            Padding(
              padding: EdgeInsets.symmetric(vertical: 8.r),
              child: Divider(
                height: 1,
                thickness: 1,
                color: theme.colorScheme.outline.withValues(alpha: 0.15),
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: IntrinsicHeight(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < _menuSections.length; i++)
                            Padding(
                              padding: EdgeInsets.only(bottom: 2.r),
                              child: _buildMenuRow(theme, i),
                            ),
                          const Spacer(),
                          _buildLogoutRow(theme),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDashboardPill(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required Color background,
    required Color foreground,
    Color? border,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 7.r, vertical: 2.r),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6.r),
        border: Border.all(color: border ?? Colors.transparent),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 9.r, color: foreground),
          SizedBox(width: 3.r),
          Text(
            label,
            style: TextStyle(
              color: foreground,
              fontSize: 7.r,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  /// A menu entry in the sidebar, the RetroAchievements menu's row: filled
  /// with the app's selection colour while the D-pad is on it, tinted while
  /// its section has the D-pad in the panel.
  Widget _buildMenuRow(ThemeData theme, int index) {
    final scheme = theme.colorScheme;
    final radii = theme.extension<CornerRadii>() ?? CornerRadii.m();
    final section = _menuSections[index];
    final current = _shownSection == section;
    final filled = index == _selectedMenuIndex && !_panelFocused;
    final background = filled
        ? scheme.onSurface
        : current
        ? scheme.onSurface.withValues(alpha: 0.10)
        : Colors.transparent;
    final foreground = filled
        ? scheme.surface
        : scheme.onSurface.withValues(alpha: current ? 1 : 0.75);
    final (icon, label) = switch (section) {
      NeoSyncSection.keptCopies => (
        Symbols.history_rounded,
        AppLocale.keptCopiesTitle,
      ),
      NeoSyncSection.customFolders => (
        Symbols.folder_special_rounded,
        AppLocale.customSaveFoldersMenu,
      ),
      NeoSyncSection.plans => (
        Symbols.payment_rounded,
        AppLocale.updateYourPlanMenu,
      ),
      _ => (Symbols.cloud_rounded, AppLocale.saveListMenu),
    };
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          SfxService().playNavSound();
          _goToSection(section);
        },
        canRequestFocus: false,
        borderRadius: radii.radiusInternal,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: 32.r,
          padding: EdgeInsets.symmetric(horizontal: 10.r),
          decoration: BoxDecoration(
            color: background,
            borderRadius: radii.radiusInternal,
          ),
          child: Row(
            children: [
              Icon(icon, size: 18.r, color: foreground),
              SizedBox(width: 10.r),
              Expanded(
                child: Text(
                  label.getString(context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 12.r,
                    fontWeight: current ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Logout at the sidebar's foot, the RetroAchievements one: red at rest,
  /// filled with the app's selection colour while the D-pad is on it.
  Widget _buildLogoutRow(ThemeData theme) {
    final scheme = theme.colorScheme;
    final radii = theme.extension<CornerRadii>() ?? CornerRadii.m();
    final selected = _logoutSelected;
    final foreground = selected ? scheme.surface : scheme.error;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _onLogout,
        canRequestFocus: false,
        borderRadius: radii.radiusInternal,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: 32.r,
          padding: EdgeInsets.symmetric(horizontal: 10.r),
          decoration: BoxDecoration(
            color: selected ? scheme.onSurface : Colors.transparent,
            borderRadius: radii.radiusInternal,
          ),
          child: Row(
            children: [
              Icon(Symbols.logout_rounded, size: 18.r, color: foreground),
              SizedBox(width: 10.r),
              Text(
                AppLocale.logout.getString(context),
                style: TextStyle(
                  color: foreground,
                  fontSize: 12.r,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Signed out: one NeoGlass panel, NeoSync introduced on the left (its
  /// logo from the neosync.cloud brand kit, in the theme's colour) and the
  /// sign-in form on the right.
  Widget _buildSignedOutLayout(BuildContext context) {
    final theme = Theme.of(context);
    final radii = theme.extension<CornerRadii>() ?? CornerRadii.m();
    final line = theme.colorScheme.outline.withValues(alpha: 0.15);
    // Anchored to the top, like the RetroAchievements and RomM sign-in
    // panels, so the three start at the same height.
    return Align(
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        // 52.r clears the top dock, the same as the other sign-in panels.
        padding: EdgeInsets.fromLTRB(16.r, 52.r, 16.r, 16.r),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 600.r),
          child: NeoGlassRim(
            cornerRadius: radii.radiusExternalRadius,
            child: Container(
              padding: EdgeInsets.all(14.r),
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
                    margin: EdgeInsets.symmetric(horizontal: 16.r),
                    color: line,
                  ),
                  Expanded(
                    child: AuthForm(
                      onLoginSuccess: _onLoginSuccess,
                      framed: false,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// NeoSync introduced: its logo, what it does and where to learn more.
  Widget _buildInfoBox(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NeoSyncLogo(height: 26.r),
        SizedBox(height: 14.r),
        Text(
          AppLocale.neoSyncDescription.getString(context),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
            fontSize: 10.r,
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
              fontSize: 10.r,
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
