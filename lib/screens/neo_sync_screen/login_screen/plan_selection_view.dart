import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/billing_models.dart';
import 'package:neostation/models/user.dart';
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/services/neosync/billing_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/centered_scroll_controller.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/widgets/core_footer.dart';
import 'package:neostation/widgets/neo_glass.dart';
import 'package:neostation/themes/corner_radii.dart';
import '../../app_screen.dart';
import 'neo_sync_shared.dart';

/// Full-screen plan selection view.
///
/// Shows the available NeoSync plans as a gamepad-navigable list (up/down to
/// browse). A single footer control performs the action for the focused plan —
/// Upgrade when it costs more than the current plan, Downgrade when it costs
/// less, and End Subscription when it is the current plan. Replaces the
/// previous upgrade dialog with a full view that has its own navigation layer.
class PlanSelectionView extends StatefulWidget {
  final List<PlanInfo> initialPlans;
  final Function(String, String) onUpgrade;
  final Function() onCancel;
  final IconData Function(String) getPlanIcon;
  final VoidCallback onBack;

  const PlanSelectionView({
    super.key,
    required this.initialPlans,
    required this.onUpgrade,
    required this.onCancel,
    required this.getPlanIcon,
    required this.onBack,
  });

  @override
  State<PlanSelectionView> createState() => _PlanSelectionViewState();
}

class _PlanSelectionViewState extends State<PlanSelectionView> {
  late GamepadNavigation _gamepadNav;
  List<PlanInfo> _plans = [];
  bool _plansLoading = true;
  String? _errorMessage;
  int _selectedPlanIndex = 0;

  static const List<String> _planOrder = [
    'free',
    'micro',
    'mini',
    'mega',
    'ultra',
  ];

  List<PlanInfo> get _availablePlans =>
      _plans.where((plan) => plan.name != 'free').toList();

  int _planRank(String planName) {
    final name = planName.toLowerCase().trim();
    for (var i = 0; i < _planOrder.length; i++) {
      if (name.contains(_planOrder[i])) return i;
    }
    return -1;
  }

  void _navigatePlanUp() {
    final plans = _availablePlans;
    if (plans.isEmpty) return;
    setState(() {
      _selectedPlanIndex = _selectedPlanIndex > 0
          ? _selectedPlanIndex - 1
          : plans.length - 1;
    });
  }

  void _navigatePlanDown() {
    final plans = _availablePlans;
    if (plans.isEmpty) return;
    setState(() {
      _selectedPlanIndex = (_selectedPlanIndex + 1) % plans.length;
    });
  }

  /// A on the focused plan: current → cancel subscription; otherwise upgrade
  /// or downgrade depending on how it compares to the user's plan.
  void _handleSelect() {
    final plans = _availablePlans;
    if (plans.isEmpty || _selectedPlanIndex >= plans.length) return;
    final plan = plans[_selectedPlanIndex];
    final user = context.read<AuthService>().currentUser;

    if (user?.plan == plan.name) {
      widget.onCancel();
    } else {
      widget.onUpgrade(plan.name, 'monthly');
    }
  }

  /// Whether the focused plan is an upgrade over [currentPlan] (a downgrade
  /// otherwise). Unknown plans are treated as upgrades.
  bool _focusedPlanIsUpgrade(String? currentPlan) {
    final plans = _availablePlans;
    if (plans.isEmpty || _selectedPlanIndex >= plans.length) return true;
    final current = currentPlan?.toLowerCase().trim() ?? '';
    if (current.isEmpty || current == 'free') return true;
    final targetRank = _planRank(plans[_selectedPlanIndex].name);
    final currentRank = _planRank(current);
    if (currentRank == -1) return true;
    if (targetRank == -1) return false;
    return targetRank > currentRank;
  }

  bool get _focusedPlanIsCurrent {
    final plans = _availablePlans;
    if (plans.isEmpty || _selectedPlanIndex >= plans.length) return false;
    return context.read<AuthService>().currentUser?.plan ==
        plans[_selectedPlanIndex].name;
  }

  @override
  void initState() {
    super.initState();
    _plans = widget.initialPlans;
    _plansLoading = widget.initialPlans.isEmpty;
    _gamepadNav = GamepadNavigation(
      onNavigateUp: (isRepeat) => _navigatePlanUp(),
      onNavigateDown: (isRepeat) => _navigatePlanDown(),
      onSelectItem: _handleSelect,
      onBack: () {
        if (mounted) widget.onBack();
      },
      onPreviousTab: () => AppNavigation.previousTab(),
      onNextTab: () => AppNavigation.nextTab(),
      onSettings: () {},
    );
    // The shell already loaded plans; still refresh in the background so the
    // view is never stale, but only block the UI if we have nothing to show.
    if (_plans.isNotEmpty) {
      _refreshPlansQuietly();
    } else {
      _loadPlans();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'neo_sync_plans',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('neo_sync_plans');
    _gamepadNav.dispose();
    super.dispose();
  }

  Future<void> _loadPlans() async {
    final authService = Provider.of<AuthService>(context, listen: false);
    if (!authService.isLoggedIn) return;

    setState(() {
      _plansLoading = true;
      _errorMessage = null;
    });

    final billingService = Provider.of<BillingService>(context, listen: false);
    final result = await billingService.getAvailablePlans();

    if (mounted) {
      setState(() {
        _plansLoading = false;
        if (result['success']) {
          _plans = result['plans'];
          _plans.sort((a, b) {
            final aOrder = _planRank(a.name);
            final bOrder = _planRank(b.name);
            return aOrder.compareTo(bOrder);
          });
          if (_availablePlans.isNotEmpty) {
            _selectedPlanIndex = 0;
          }
        } else {
          _errorMessage = result['message'];
        }
      });
    }
  }

  /// Refreshes the plan list in the background without showing a loading
  /// spinner — used when the shell already handed us fresh plans.
  Future<void> _refreshPlansQuietly() async {
    final authService = Provider.of<AuthService>(context, listen: false);
    if (!authService.isLoggedIn) return;

    final billingService = Provider.of<BillingService>(context, listen: false);
    final result = await billingService.getAvailablePlans();

    if (mounted && result['success']) {
      setState(() {
        _plans = result['plans'];
        _plans.sort((a, b) {
          final aOrder = _planRank(a.name);
          final bOrder = _planRank(b.name);
          return aOrder.compareTo(bOrder);
        });
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = context.watch<AuthService>().currentUser;

    return Padding(
      padding: EdgeInsets.only(top: 52.r, left: 8.r, right: 8.r, bottom: 8.r),
      child: Column(
        children: [
          NeoSyncSectionHeader(
            icon: Symbols.payment_rounded,
            title: AppLocale.manageYourPlan
                .getString(context)
                .replaceFirst('{plan}', user?.plan.toUpperCase() ?? ''),
          ),
          SizedBox(height: 8.r),
          Expanded(
            child: NeoGlassRim(
              cornerRadius: (theme.extension<CornerRadii>() ?? CornerRadii.m())
                  .radiusExternalRadius,
              child: Container(
                padding: EdgeInsets.all(12.r),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius:
                      (theme.extension<CornerRadii>() ?? CornerRadii.m())
                          .radiusExternal,
                  border: Border.all(
                    color: theme.colorScheme.outline.withValues(alpha: 0.15),
                  ),
                ),
                child: _buildPlansContent(context, user),
              ),
            ),
          ),
          SizedBox(height: 6.r),
          _buildFooter(context, user),
        ],
      ),
    );
  }

  Widget _buildPlansContent(BuildContext context, User? currentUser) {
    final theme = Theme.of(context);

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.error_outline_rounded,
              color: theme.colorScheme.error,
              size: 48.r,
            ),
            SizedBox(height: 8.r),
            Text(
              _errorMessage!,
              style: TextStyle(
                fontSize: 12.r,
                color: theme.colorScheme.error,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 8.r),
            ElevatedButton.icon(
              onPressed: _loadPlans,
              icon: Icon(Symbols.refresh_rounded, size: 16.r),
              label: Text(AppLocale.retry.getString(context)),
            ),
          ],
        ),
      );
    }

    if (_plansLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: theme.colorScheme.primary),
            SizedBox(height: 8.r),
            Text(
              AppLocale.loadingPlans.getString(context),
              style: TextStyle(
                fontSize: 12.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      );
    }

    if (_plans.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.payment_rounded,
              size: 48.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
            SizedBox(height: 8.r),
            Text(
              AppLocale.noPlansAvailable.getString(context),
              style: TextStyle(
                fontSize: 12.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            SizedBox(height: 8.r),
            ElevatedButton.icon(
              onPressed: _loadPlans,
              icon: Icon(Symbols.refresh_rounded, size: 16.r),
              label: Text(AppLocale.retry.getString(context)),
            ),
          ],
        ),
      );
    }

    return PlanListView(
      plans: _availablePlans,
      currentPlan: currentUser?.plan,
      selectedIndex: _selectedPlanIndex,
      getPlanIcon: widget.getPlanIcon,
      onSelectionChanged: (index) {
        if (mounted) setState(() => _selectedPlanIndex = index);
      },
    );
  }

  Widget _buildFooter(BuildContext context, User? user) {
    final theme = Theme.of(context);

    final String actionLabel;
    final Color actionColor;
    final Color actionTextColor;
    if (_focusedPlanIsCurrent) {
      actionLabel = AppLocale.endSubscription.getString(context);
      actionColor = theme.colorScheme.tertiaryFixed;
      actionTextColor = theme.colorScheme.onTertiaryFixed;
    } else if (_focusedPlanIsUpgrade(user?.plan)) {
      actionLabel = AppLocale.upgrade.getString(context);
      actionColor = theme.colorScheme.primary;
      actionTextColor = theme.colorScheme.onPrimary;
    } else {
      actionLabel = AppLocale.downgrade.getString(context);
      actionColor = theme.colorScheme.tertiary;
      actionTextColor = theme.colorScheme.onTertiary;
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        GamepadControl(
          label: actionLabel,
          iconPath: 'assets/images/gamepad/Xbox_A_button.png',
          onTap: _handleSelect,
          textColor: actionTextColor,
          backgroundColor: actionColor,
        ),
        SizedBox(width: 8.r),
        NeoSyncBackButton(onTap: () => widget.onBack()),
      ],
    );
  }
}

/// Gamepad-navigable, centered plan list.
///
/// Mirrors the online saves list: a fixed-height list whose selection highlight
/// is drawn on its own layer and the viewport is scrolled to keep the focused
/// plan centered as the user navigates.
class PlanListView extends StatefulWidget {
  final List<PlanInfo> plans;
  final String? currentPlan;
  final int selectedIndex;
  final IconData Function(String) getPlanIcon;
  final Function(int) onSelectionChanged;

  const PlanListView({
    super.key,
    required this.plans,
    required this.currentPlan,
    required this.selectedIndex,
    required this.getPlanIcon,
    required this.onSelectionChanged,
  });

  @override
  State<PlanListView> createState() => _PlanListViewState();
}

class _PlanListViewState extends State<PlanListView>
    with TickerProviderStateMixin {
  late final CenteredScrollController _centeredScrollController;
  late AnimationController _selectionController;
  late Animation<double> _selectionAnimation;

  @override
  void initState() {
    super.initState();

    _centeredScrollController = CenteredScrollController(centerPosition: 0.5);

    _selectionController = AnimationController(
      duration: const Duration(milliseconds: 120),
      vsync: this,
    );
    _selectionAnimation = AlwaysStoppedAnimation(
      widget.selectedIndex.toDouble(),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _centeredScrollController.initialize(
          context: context,
          initialIndex: widget.selectedIndex,
          totalItems: widget.plans.length,
        );
        _centeredScrollController.scrollToIndex(
          widget.selectedIndex,
          immediate: true,
        );
      }
    });
  }

  @override
  void didUpdateWidget(PlanListView oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.plans.length != widget.plans.length) {
      _centeredScrollController.updateTotalItems(widget.plans.length);
    }

    if (oldWidget.selectedIndex != widget.selectedIndex) {
      final animationDuration = const Duration(milliseconds: 250);
      final scrollDuration = const Duration(milliseconds: 360);
      const curve = Curves.easeOutQuart;

      final double begin = _selectionAnimation.value;
      final double end = widget.selectedIndex.toDouble();

      _selectionController.duration = animationDuration;
      _selectionAnimation = Tween<double>(
        begin: begin,
        end: end,
      ).animate(CurvedAnimation(parent: _selectionController, curve: curve));

      _selectionController.forward(from: 0);

      _centeredScrollController.updateSelectedIndex(widget.selectedIndex);
      if (_centeredScrollController.scrollController.hasClients) {
        _centeredScrollController.scrollToIndex(
          widget.selectedIndex,
          duration: scrollDuration,
          curve: curve,
        );
      }
    }
  }

  @override
  void dispose() {
    _centeredScrollController.dispose();
    _selectionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final double itemHeight = 64.r;
    final double marginBottom = 8.r;
    final double totalItemHeight = itemHeight + marginBottom;

    return Stack(
      children: [
        // Highlight layer
        AnimatedBuilder(
          animation: Listenable.merge([
            _selectionController,
            _centeredScrollController.scrollController,
          ]),
          builder: (context, child) {
            final double scrollOffset =
                _centeredScrollController.scrollController.hasClients
                ? _centeredScrollController.scrollController.offset
                : 0.0;

            final double currentSelection = _selectionAnimation.value;
            final double topPosition =
                (currentSelection * totalItemHeight) + 4.r - scrollOffset;

            return Positioned(
              top: topPosition,
              left: 4.r,
              right: 4.r,
              height: itemHeight,
              child: Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurface,
                  borderRadius: BorderRadius.circular(12.r),
                ),
              ),
            );
          },
        ),
        // List layer
        ValueListenableBuilder<int>(
          valueListenable: _centeredScrollController.rebuildNotifier,
          builder: (context, rebuildCount, _) {
            return ListView.builder(
              key: ValueKey('plan_list_$rebuildCount'),
              controller: _centeredScrollController.scrollController,
              padding: EdgeInsets.symmetric(vertical: 4.r, horizontal: 4.w),
              itemCount: widget.plans.length,
              itemBuilder: (context, index) {
                return GestureDetector(
                  onTap: () {
                    SfxService().playNavSound();
                    widget.onSelectionChanged(index);
                  },
                  child: _buildPlanItem(context, widget.plans[index], index),
                );
              },
            );
          },
        ),
      ],
    );
  }

  Widget _buildPlanItem(BuildContext context, PlanInfo plan, int index) {
    final theme = Theme.of(context);
    final isCurrentPlan = widget.currentPlan == plan.name;
    final isSelected = index == widget.selectedIndex;

    final Color primaryColor = isSelected
        ? theme.colorScheme.surface
        : theme.colorScheme.primary;
    final Color secondaryColor = isSelected
        ? theme.colorScheme.surface.withValues(alpha: 0.8)
        : theme.colorScheme.onSurface.withValues(alpha: 0.6);

    return Container(
      key: ValueKey('plan_item_$index'),
      height: 64.r,
      margin: EdgeInsets.only(bottom: 8.r),
      padding: EdgeInsets.symmetric(horizontal: 12.r),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        plan.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.r,
                          fontWeight: isSelected
                              ? FontWeight.bold
                              : FontWeight.w600,
                          color: isSelected
                              ? theme.colorScheme.surface
                              : theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                    if (isCurrentPlan) ...[
                      SizedBox(width: 6.r),
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 5.r,
                          vertical: 1.r,
                        ),
                        decoration: BoxDecoration(
                          color: primaryColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(5.r),
                        ),
                        child: Text(
                          AppLocale.currentBadge.getString(context),
                          style: TextStyle(
                            fontSize: 6.r,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.4.r,
                            color: primaryColor,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                SizedBox(height: 2.r),
                Row(
                  children: [
                    Icon(
                      Symbols.cloud_rounded,
                      size: 9.r,
                      color: primaryColor.withValues(alpha: 0.7),
                    ),
                    SizedBox(width: 4.r),
                    Flexible(
                      child: Text(
                        plan.storageQuotaFormatted,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 9.r, color: secondaryColor),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(width: 12.r),
          // Monthly price block
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '\$${plan.priceMonthly.toStringAsFixed(2)}',
                style: TextStyle(
                  fontSize: 15.r,
                  fontWeight: FontWeight.bold,
                  color: isSelected
                      ? theme.colorScheme.surface
                      : theme.colorScheme.onSurface,
                ),
              ),
              Text(
                '/${AppLocale.monthly.getString(context)}',
                style: TextStyle(
                  fontSize: 8.r,
                  color: secondaryColor.withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
          if (isCurrentPlan) ...[
            SizedBox(width: 8.r),
            Icon(Symbols.check_circle_rounded, size: 18.r, color: primaryColor),
          ],
        ],
      ),
    );
  }
}
