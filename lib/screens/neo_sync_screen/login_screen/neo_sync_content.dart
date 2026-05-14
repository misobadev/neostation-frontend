import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/widgets/custom_notification.dart' as custom;
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/services/game_service.dart';
import 'package:neostation/widgets/auth_form.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/services/notification_service.dart';
import 'package:neostation/services/neosync/billing_service.dart';
import 'package:neostation/models/billing_models.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:provider/provider.dart';
import 'package:flutter/gestures.dart';
import '../../../models/neo_sync_models.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/repositories/game_repository.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import '../../app_screen.dart';
import 'package:neostation/utils/centered_scroll_controller.dart';

class NeoSyncContent extends StatefulWidget {
  const NeoSyncContent({super.key});

  @override
  NeoSyncContentState createState() => NeoSyncContentState();
}

class NeoSyncContentState extends State<NeoSyncContent>
    with TickerProviderStateMixin {
  static bool _dataLoadedThisSession = false;
  bool _isRefreshingOnlineFiles = false;
  bool _refreshCompleted = false;
  int _selectedSaveIndex = 0; // Índice del save seleccionado con gamepad
  late GamepadNavigation _savesGamepadNav;
  final GlobalKey<OnlineSavesListViewState> _onlineSavesListKey =
      GlobalKey<OnlineSavesListViewState>();
  bool _isNavigatingFast = false;

  // Throttling para evitar eventos duplicados muy rápidos
  DateTime? _lastSelectTime;
  static const int _selectThrottleMs = 500;

  // Debouncing for cloud refresh
  DateTime? _lastRefreshTime;

  // Variables para el modo dialog
  final bool _isDialogMode = false;
  final bool _dialogDisableNeoSync = false;
  Function(bool)? _dialogOnDisableNeoSyncChanged;

  // Variables para billing
  List<PlanInfo> _plans = [];
  static bool _plansLoadedThisSession = false;
  bool _isProfileLoading = false;
  static bool _profileLoaded = false;

  late final FocusNode _upgradeButtonFocusNode;

  void _handleDialogBack() {
    if (_isDialogMode) {
      Navigator.of(context).pop(false);
    }
  }

  // Métodos para billing
  Future<void> _loadProfileIfNeeded() async {
    final authService = Provider.of<AuthService>(context, listen: false);

    // Only load profile if we don't have user data or if it's incomplete or if flag was reset
    if (!_profileLoaded ||
        authService.currentUser == null ||
        authService.currentUser!.username.isEmpty) {
      setState(() {
        _isProfileLoading = true;
      });

      await authService.getProfile();
      _profileLoaded = true;

      if (mounted) {
        setState(() {
          _isProfileLoading = false;
        });
      }
    }
  }

  Future<void> _loadPlansIfNeeded() async {
    final authService = Provider.of<AuthService>(context, listen: false);
    final billingService = Provider.of<BillingService>(context, listen: false);

    // Only load plans if we haven't loaded them this session or if we don't have any
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
        // Force refresh profile data immediately after successful upgrade
        if (!mounted) return;
        final authService = Provider.of<AuthService>(context, listen: false);
        await authService.getProfile();

        // Also trigger widget refresh
        if (mounted) setState(() {});
      } else {
        final session = result['session'] as BillingSession;

        if (await canLaunchUrl(Uri.parse(session.url))) {
          try {
            await launchUrl(
              Uri.parse(session.url),
              mode: LaunchMode.externalApplication,
            );
            // WebSocket notification will trigger refresh when payment completes
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

    // Desactivar navegación por gamepad antes de abrir el modal
    _savesGamepadNav.deactivate();

    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return _CancelSubscriptionDialog(
          onKeepSubscription: () => Navigator.of(context).pop(false),
          onCancelSubscription: () => Navigator.of(context).pop(true),
        );
      },
    );

    // Reactivar navegación por gamepad después de cerrar el modal
    _savesGamepadNav.activate();

    if (confirmed != true) {
      // User pressed B (back) and decided to keep subscription
      // Refresh data anyway to ensure UI is up to date
      if (mounted) {
        final neoSyncProvider = Provider.of<NeoSyncProvider>(
          context,
          listen: false,
        );

        // Refresh profile to get latest subscription info
        await authService.getProfile();
        // Refresh storage quota and files
        await neoSyncProvider.loadQuota();
        await neoSyncProvider.loadOnlineFiles();

        if (mounted) {
          _resetSelection();
        }
      }
      return;
    }

    final result = await billingService.cancelSubscription(user.id);

    if (result['success']) {
      // Refresh profile data
      await authService.getProfile();

      // Refresh storage quota and online files
      if (mounted) {
        final neoSyncProvider = Provider.of<NeoSyncProvider>(
          context,
          listen: false,
        );
        await neoSyncProvider.loadQuota();
        await neoSyncProvider.loadOnlineFiles();

        _resetSelection();
      }

      // Show success dialog
      if (mounted) {
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (BuildContext context) {
            return _SuccessDialog(
              title: AppLocale.cancelSubscription.getString(context),
              message: AppLocale.cancelSubscriptionConfirm.getString(context),
              onClose: () => Navigator.of(context).pop(),
            );
          },
        );
      }
    } else {
      // Show error dialog
      if (mounted) {
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (BuildContext context) {
            return _ErrorDialog(
              title: AppLocale.error.getString(context),
              message: result['message'] ?? AppLocale.error.getString(context),
              onClose: () => Navigator.of(context).pop(),
            );
          },
        );
      }
    }
  }

  IconData _getPlanIcon(String planName) {
    switch (planName) {
      case 'micro':
        return Symbols.storage_rounded;
      case 'mini':
        return Symbols.storage_rounded;
      case 'mega':
        return Symbols.storage_rounded;
      case 'ultra':
        return Symbols.storage_rounded;
      default:
        return Symbols.storage_rounded;
    }
  }

  void _showUpgradeModal() async {
    // Desactivar todas las navegaciones antes de abrir el modal
    _savesGamepadNav.deactivate();

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return _UpgradeModalDialog(
          plans: _plans,
          onUpgrade: _upgradePlan,
          onCancel: _cancelSubscription,
          getPlanIcon: _getPlanIcon,
        );
      },
    );

    // Refresh quota and online files after closing the modal
    if (mounted) {
      final neoSyncProvider = Provider.of<NeoSyncProvider>(
        context,
        listen: false,
      );
      final authService = Provider.of<AuthService>(context, listen: false);

      // Refresh profile to get updated plan info
      await authService.getProfile();

      // Refresh storage quota and files
      await neoSyncProvider.loadQuota();
      await neoSyncProvider.loadOnlineFiles();

      _resetSelection();
    }

    // Reactivar todas las navegaciones después de cerrar el modal
    _savesGamepadNav.activate();
  }

  Widget _buildProfileCard() {
    final authService = Provider.of<AuthService>(context);
    final neoSyncProvider = Provider.of<NeoSyncProvider>(context);
    final theme = Theme.of(context);

    if (_isProfileLoading) {
      return Center(child: CircularProgressIndicator());
    }

    final user = authService.currentUser;

    if (user == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(AppLocale.failedToLoadProfile.getString(context)),
            SizedBox(height: 16.r),
            ElevatedButton(
              onPressed: _loadProfileIfNeeded,
              child: Text(AppLocale.retry.getString(context)),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Steam-style NeoSync Dashboard (Compacto)
        Container(
          padding: EdgeInsets.all(12.r),
          decoration: BoxDecoration(
            color: theme.cardColor.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(12.r),
            border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.15),
              width: 1.r,
            ),
          ),
          child: Column(
            children: [
              // Steam-style Header con usuario y plan (Compacto)
              Row(
                children: [
                  SizedBox(width: 2.r),
                  // Info del usuario expandida (más compacta)
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                AppLocale.helloUser
                                    .getString(context)
                                    .replaceFirst('{name}', user.username),
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurface,
                                      fontSize: 10.r,
                                    ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 3.r),
                        Row(
                          children: [
                            Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: 6.r,
                                vertical: 2.r,
                              ),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.secondary,
                                borderRadius: BorderRadius.circular(6.r),
                              ),
                              child: Text(
                                '${user.plan.toUpperCase()} ${AppLocale.quota.getString(context).toUpperCase()}',
                                style: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSecondary,
                                  fontSize: 7.r,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            SizedBox(width: 3.r),
                            Flexible(
                              child: Text(
                                AppLocale.member.getString(context),
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: 0.7),
                                      fontSize: 8.r,
                                    ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // Botón logout mejorado (más compacto)
                  IconButton(
                    onPressed: _onLogout,
                    icon: Icon(
                      Symbols.logout_rounded,
                      size: 12.r,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    tooltip: AppLocale.logout.getString(context),
                    style: IconButton.styleFrom(
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.error.withValues(alpha: 0.1),
                      padding: EdgeInsets.all(8.r),
                      minimumSize: Size(32.r, 32.r),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 8.r),
              // Status de conexión Steam-style (Compacto)
              Container(
                padding: EdgeInsets.all(8.r),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8.r),
                  border: Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.15),
                    width: 1.r,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: EdgeInsets.all(4.r),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(6.r),
                      ),
                      child: Icon(
                        Symbols.cloud_done_rounded,
                        color: Theme.of(context).colorScheme.primary,
                        size: 14.r,
                      ),
                    ),
                    SizedBox(width: 6.r),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            AppLocale.neoSyncSynchronized.getString(context),
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface,
                                  fontSize: 10.r,
                                ),
                          ),
                          Text(
                            AppLocale.cloudSyncOn.getString(context),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurface
                                      .withValues(alpha: 0.7),
                                  fontSize: 8.r,
                                ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      width: 6.r,
                      height: 6.r,
                      decoration: BoxDecoration(
                        color: Colors.green.shade400,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.green.shade400.withValues(alpha: 0.5),
                            blurRadius: 4.r,
                            spreadRadius: 1.r,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 8.r),
              // Storage quota Steam-style (Compacto)
              if (neoSyncProvider.quota != null) ...[
                Container(
                  padding: EdgeInsets.all(8.r),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: theme.colorScheme.primary.withValues(alpha: 0.15),
                      width: 1.r,
                    ),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Icon(
                            Symbols.storage_rounded,
                            color: Theme.of(context).colorScheme.primary,
                            size: 16.r,
                          ),
                          SizedBox(width: 3.r),
                          Text(
                            AppLocale.cloudSaveTitle.getString(context),
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 10.r,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface,
                                ),
                          ),
                          const Spacer(),
                          Text(
                            '${neoSyncProvider.quota!.usagePercentage.toStringAsFixed(1)}%',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 10.r,
                                  color:
                                      neoSyncProvider.quota!.usagePercentage >=
                                          90
                                      ? Colors.red.shade400
                                      : Theme.of(context).colorScheme.primary,
                                ),
                          ),
                        ],
                      ),
                      SizedBox(height: 3.r),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            neoSyncProvider.quota!.usedQuotaFormatted,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurface
                                      .withValues(alpha: 0.8),
                                  fontSize: 8.r,
                                ),
                          ),
                          Text(
                            neoSyncProvider.quota!.totalQuotaFormatted,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurface
                                      .withValues(alpha: 0.8),
                                  fontSize: 8.r,
                                ),
                          ),
                        ],
                      ),
                      SizedBox(height: 3.r),
                      Container(
                        height: 4.r,
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest
                              .withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: neoSyncProvider.quota!.usagePercentage / 100,
                            backgroundColor: Colors.transparent,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              neoSyncProvider.quota!.usagePercentage >= 100
                                  ? Colors.red.shade400
                                  : neoSyncProvider.quota!.usagePercentage >= 90
                                  ? Colors.orange.shade400
                                  : Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 8.r),
              ],
              // Upgrade Plan Steam-style button (Compacto)
              SizedBox(
                width: double.infinity,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.green.shade600,
                    borderRadius: BorderRadius.circular(6.r),
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      canRequestFocus: false,
                      focusColor: Colors.transparent,
                      hoverColor: Colors.transparent,
                      highlightColor: Colors.transparent,
                      splashColor: Colors.transparent,
                      focusNode: _upgradeButtonFocusNode,
                      borderRadius: BorderRadius.circular(6),
                      onTap: () {
                        SfxService().playNavSound();
                        _showUpgradeModal();
                      },
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          vertical: 6.r,
                          horizontal: 8.r,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Image.asset(
                              'assets/images/gamepad/Xbox_Y_button.png',
                              width: 18.r,
                              height: 18.r,
                              color: Colors.white,
                            ),
                            Text(
                              AppLocale.upgradePlan.getString(context),
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 10.r,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
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
      ],
    );
  }

  void _initializeGamepad() {
    _savesGamepadNav = GamepadNavigation(
      onNavigateUp: (isRepeat) {
        if (_isNavigatingFast != isRepeat) {
          setState(() => _isNavigatingFast = isRepeat);
        }
        _navigateSavesUp();
      },
      onNavigateDown: (isRepeat) {
        if (_isNavigatingFast != isRepeat) {
          setState(() => _isNavigatingFast = isRepeat);
        }
        _navigateSavesDown();
      },
      onSelectItem: _selectSaveItem,
      onPreviousTab: () {
        // Ignorar LB cuando estamos en un dialog modal
        if (_isDialogMode) return;
        return AppNavigation.previousTab();
      },
      onNextTab: () {
        // Ignorar RB cuando estamos en un dialog modal
        if (_isDialogMode) return;
        return AppNavigation.nextTab();
      },
      onBack:
          _handleDialogBack, // Usar el método que maneja tanto dialog como normal
      onFavorite: () {
        // Asegurar que la navegación esté activa antes de abrir el modal
        if (!_savesGamepadNav.isActive) {
          _savesGamepadNav.activate();
        }
        _showUpgradeModal();
      }, // Y button para abrir upgrade modal directamente
    );

    // Establecer contexto en NotificationService para mostrar modales inmediatamente
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _savesGamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'neo_sync_content',
        onActivate: () {
          _savesGamepadNav.activate();
          _resetSelection();
        },
        onDeactivate: () => _savesGamepadNav.deactivate(),
      );

      final notificationService = Provider.of<NotificationService>(
        context,
        listen: false,
      );
      notificationService.setContext(context);
      _loadInitialDataIfNeeded();

      // Inicializar navegación por gamepad para saves
    });
  }

  @override
  void initState() {
    super.initState();
    // Reset data loaded flag if this is a fresh app start (user not logged in)
    final authService = Provider.of<AuthService>(context, listen: false);
    if (!authService.isLoggedIn) {
      _dataLoadedThisSession = false;
    }

    _upgradeButtonFocusNode = FocusNode(skipTraversal: true);

    _loadProfileIfNeeded();
    _loadPlansIfNeeded();

    // Inicializar navegación por gamepad para la lista de saves
    _initializeGamepad();
  }

  void _cleanupResources() {
    GamepadNavigationManager.popLayer('neo_sync_content');
    _savesGamepadNav.dispose();
  }

  @override
  void dispose() {
    _upgradeButtonFocusNode.dispose();
    _cleanupResources();
    super.dispose();
  }

  void _resetSelection() {
    if (!mounted) return;

    setState(() {
      _selectedSaveIndex = 0;
    });
  }

  void _navigateSavesUp() {
    final neoSyncProvider = Provider.of<NeoSyncProvider>(
      context,
      listen: false,
    );
    if (neoSyncProvider.onlineFiles.isNotEmpty) {
      final newIndex = _selectedSaveIndex > 0
          ? _selectedSaveIndex - 1
          : neoSyncProvider.onlineFiles.length - 1;
      _updateSelectionIndex(newIndex);
    }
  }

  void _navigateSavesDown() {
    final neoSyncProvider = Provider.of<NeoSyncProvider>(
      context,
      listen: false,
    );
    if (neoSyncProvider.onlineFiles.isNotEmpty) {
      final newIndex =
          (_selectedSaveIndex + 1) % neoSyncProvider.onlineFiles.length;
      _updateSelectionIndex(newIndex);
    }
  }

  void _updateSelectionIndex(int newIndex) {
    if (_selectedSaveIndex == newIndex) return;

    setState(() {
      _selectedSaveIndex = newIndex;
    });
  }

  void _selectSaveItem() async {
    // Si estamos en modo dialog, manejar la acción del dialog
    if (_isDialogMode) {
      _dialogOnDisableNeoSyncChanged?.call(_dialogDisableNeoSync);
      Navigator.of(context).pop(true);
      return;
    }

    // Throttling para evitar eventos duplicados muy rápidos
    final now = DateTime.now();
    if (_lastSelectTime != null &&
        now.difference(_lastSelectTime!).inMilliseconds < _selectThrottleMs) {
      return;
    }
    _lastSelectTime = now;

    final neoSyncProvider = Provider.of<NeoSyncProvider>(
      context,
      listen: false,
    );
    if (neoSyncProvider.onlineFiles.isNotEmpty &&
        _selectedSaveIndex < neoSyncProvider.onlineFiles.length) {
      final selectedFile = neoSyncProvider.onlineFiles[_selectedSaveIndex];

      bool disableNeoSync = false; // Estado del checkbox, por defecto false

      final confirmed = await _showDeleteDialog(selectedFile, (value) {
        disableNeoSync = value;
      });

      if (confirmed == true) {
        // Si el usuario marcó el checkbox, desactivar NeoSync para este juego
        if (disableNeoSync) {
          try {
            // Buscar el sistema y filename del juego usando el gameName
            final systemFolderName =
                await GameRepository.getSystemFolderForGame(
                  selectedFile.gameName,
                );
            if (systemFolderName != null) {
              await GameRepository.updateCloudSyncEnabled(
                systemFolderName,
                selectedFile.gameName,
                false,
              );
            }
          } catch (e) {
            // Mostrar error pero continuar con la eliminación
            if (!mounted) return;
            custom.AppNotification.showNotification(
              context,
              AppLocale.failedToDisableNeoSync.getString(context),
              type: custom.NotificationType.error,
            );
          }
        }

        final success = await neoSyncProvider.deleteOnlineFile(selectedFile.id);
        if (success) {
          // Ajustar índice seleccionado si es necesario después de eliminar
          final remainingFiles = neoSyncProvider.onlineFiles.length - 1;
          if (_selectedSaveIndex >= remainingFiles && remainingFiles > 0) {
            setState(() {
              _selectedSaveIndex = remainingFiles - 1;
            });
          } else if (remainingFiles == 0) {
            setState(() {
              _selectedSaveIndex = 0;
            });
          }

          // Actualizar el quota después de eliminar el archivo
          await neoSyncProvider.loadQuota();
          // Show success message
          if (!mounted) return;
          custom.AppNotification.showNotification(
            context,
            AppLocale.saveFileDeleted.getString(context),
            type: custom.NotificationType.success,
          );
        } else {
          // Show error message
          if (!mounted) return;
          custom.AppNotification.showNotification(
            context,
            AppLocale.failedToDeleteSave.getString(context),
            type: custom.NotificationType.error,
          );
        }
      }
    } else {}
  }

  Future<bool?> _showDeleteDialog(
    NeoSyncFile file,
    Function(bool) onDisableNeoSyncChanged,
  ) async {
    // Desactivar navegación principal antes de mostrar el dialog
    _savesGamepadNav.deactivate();

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return _DeleteCloudSaveDialog(
          file: file,
          onDisableNeoSyncChanged: onDisableNeoSyncChanged,
        );
      },
    );

    // Reactivar navegación principal después de cerrar el dialog
    _savesGamepadNav.activate();

    return result;
  }

  bool _isInitialLoadInProgress = false;

  Future<void> _loadInitialDataIfNeeded() async {
    final authService = Provider.of<AuthService>(context, listen: false);
    final neoSyncProvider = Provider.of<NeoSyncProvider>(
      context,
      listen: false,
    );

    // Guard against concurrent loads
    if (_isInitialLoadInProgress) return;

    // Only load if user is logged in and we haven't loaded this session
    if (authService.isLoggedIn && !_dataLoadedThisSession) {
      _isInitialLoadInProgress = true;
      // Force UI update to prevent build method from scheduling more callbacks
      if (mounted) setState(() {});

      try {
        await authService.getProfile();
        await neoSyncProvider.loadQuota();
        await neoSyncProvider.loadOnlineFiles();

        // Mark that we've loaded data this session
        _dataLoadedThisSession = true;

        _resetSelection();
      } finally {
        if (mounted) {
          setState(() {
            _isInitialLoadInProgress = false;
          });
        }
      }
    }
  }

  Future<void> _refreshOnlineFiles() async {
    // Debounce: don't refresh if already refreshing or recently refreshed
    if (_isRefreshingOnlineFiles || _refreshCompleted) {
      return;
    }

    // Check if we refreshed recently (within last 3 seconds for manual refresh)
    final now = DateTime.now();
    if (_lastRefreshTime != null &&
        now.difference(_lastRefreshTime!).inSeconds < 3) {
      return;
    }

    setState(() {
      _isRefreshingOnlineFiles = true;
      _refreshCompleted = false;
      _lastRefreshTime = now;
    });

    try {
      final authService = Provider.of<AuthService>(context, listen: false);
      final neoSyncProvider = Provider.of<NeoSyncProvider>(
        context,
        listen: false,
      );

      // Refresh both quota and online files
      await authService.getProfile();
      await neoSyncProvider.loadQuota();
      await neoSyncProvider.loadOnlineFiles();

      if (context.mounted) {
        // Resetear índice seleccionado después de refrescar
        _resetSelection();

        // Mostrar check mark por 5 segundos
        setState(() {
          _isRefreshingOnlineFiles = false;
          _refreshCompleted = true;
        });

        // Después de 3 segundos, volver al estado normal
        Future.delayed(Duration(seconds: 3), () {
          if (context.mounted) {
            setState(() {
              _refreshCompleted = false;
            });
          }
        });

        if (!mounted) return;
        custom.AppNotification.showNotification(
          context,
          AppLocale.cloudStorageRefreshed.getString(context),
          type: custom.NotificationType.info,
        );
      }
    } catch (e) {
      if (context.mounted) {
        setState(() {
          _isRefreshingOnlineFiles = false;
          _refreshCompleted = false;
        });
        if (!mounted) return;
        custom.AppNotification.showNotification(
          context,
          AppLocale.failedToRefreshCloud.getString(context),
          type: custom.NotificationType.error,
        );
      }
    }
  }

  void _onLoginSuccess() async {
    // Refresh quota and online files after successful login
    final neoSyncProvider = Provider.of<NeoSyncProvider>(
      context,
      listen: false,
    );

    await neoSyncProvider.loadQuota();
    await neoSyncProvider.loadOnlineFiles();

    // Update scroll controller with new data
    if (mounted) {
      _resetSelection();
    }
  }

  void _onLogout() {
    final authService = Provider.of<AuthService>(context, listen: false);
    authService.logout();
    // Reset profile loaded flag for next login
    _profileLoaded = false;
    // Note: We don't reset _dataLoadedThisSession here because we want to keep data loaded during app session
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // Actualizar contexto en NotificationService en cada build
    final notificationService = Provider.of<NotificationService>(
      context,
      listen: false,
    );
    notificationService.setContext(context);

    return Consumer<AuthService>(
      builder: (context, authService, child) {
        // Load initial data when user logs in (only once per app session)
        if (authService.isLoggedIn &&
            !_dataLoadedThisSession &&
            !_isInitialLoadInProgress) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _loadInitialDataIfNeeded();
          });
        }

        if (!authService.isLoggedIn) {
          return Column(
            children: [
              SizedBox(height: 64.r), // Space for header
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
          body: _buildDesktopLayout(),
        );
      },
    );
  }

  Widget _buildDesktopLayout() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Padding(
          padding: EdgeInsets.only(
            top: 52.r,
            left: 8.r,
            right: 8.r,
            bottom: 8.r,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Columna izquierda: Profile y Welcome (fija, no hace scroll)
              SizedBox(
                width: 240.w, // Ancho reducido para maximizar espacio de saves
                height:
                    constraints.maxHeight -
                    32.r, // Altura completa menos padding
                child: SingleChildScrollView(child: _buildProfileCard()),
              ),
              SizedBox(width: 8.r),
              // Columna derecha: Online Saves (con scroll independiente)
              Expanded(
                child: SizedBox(
                  height:
                      constraints.maxHeight -
                      32.r, // Altura completa menos padding
                  child: _buildOnlineSavesColumn(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildOnlineSavesColumn() {
    return Consumer<NeoSyncProvider>(
      builder: (context, neoSyncProvider, child) {
        return Container(
          padding: EdgeInsets.all(6.r),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(12.r),
            border: Border.all(
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.15),
              width: 1.r,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header (fijo en la parte superior)
              Row(
                children: [
                  SizedBox(width: 8.r),
                  Icon(
                    Symbols.cloud_rounded,
                    color: Theme.of(context).colorScheme.primary,
                    size: 16.r,
                  ),
                  SizedBox(width: 8.r),
                  Text(
                    AppLocale.onlineSaves.getString(context),
                    style: TextStyle(
                      fontSize: 12.r,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  Spacer(),
                  IconButton(
                    onPressed: (_isRefreshingOnlineFiles || _refreshCompleted)
                        ? null
                        : () async {
                            await _refreshOnlineFiles();
                          },
                    icon: _isRefreshingOnlineFiles
                        ? SizedBox(
                            width: 12.r,
                            height: 12.r,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.r,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          )
                        : _refreshCompleted
                        ? Icon(
                            Symbols.check_circle_rounded,
                            color: Theme.of(context).colorScheme.primary,
                            size: 16.r,
                          )
                        : Icon(Symbols.refresh_rounded, size: 16.r),
                    tooltip: _isRefreshingOnlineFiles
                        ? AppLocale.refreshing.getString(context)
                        : _refreshCompleted
                        ? AppLocale.refreshed.getString(context)
                        : AppLocale.refresh.getString(context),
                  ),
                ],
              ),
              SizedBox(height: 2.r),

              Expanded(
                child: neoSyncProvider.isLoadingOnlineFiles
                    ? const Center(child: CircularProgressIndicator())
                    : neoSyncProvider.onlineFiles.isEmpty
                    ? _buildEmptyState(context)
                    : OnlineSavesListView(
                        key: _onlineSavesListKey,
                        files: neoSyncProvider.onlineFiles,
                        selectedIndex: _selectedSaveIndex,
                        isNavigatingFast: _isNavigatingFast,
                        onDeleteRequest: (file, index) async {
                          // This logic can be simplified but essentially it's the same
                          // we can trigger the deletion logic here or move it to a method
                          setState(() => _selectedSaveIndex = index);
                          _selectSaveItem();
                        },
                        onSelectionChanged: (index) {
                          _updateSelectionIndex(index);
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(12.r),
        child: Column(
          children: [
            Icon(
              Symbols.cloud_off_rounded,
              size: 48.sp,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.5),
            ),
            SizedBox(height: 8.r),
            Text(
              AppLocale.noOnlineSavesFound.getString(context),
              style: TextStyle(
                fontSize: 16.r,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ],
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
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Symbols.cloud_rounded, color: theme.colorScheme.primary, size: 24.r),
              SizedBox(width: 12.r),
              Text(
                AppLocale.whatIsNeoSync.getString(context),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                  fontSize: 14.r,
                ),
              ),
            ],
          ),
          SizedBox(height: 8.r),
          Text(
            AppLocale.neoSyncDescription.getString(context),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontSize: 8.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
            ),
            softWrap: true,
          ),
          SizedBox(height: 6.r),
          _buildInfoItem(
            context,
            Symbols.cloud_upload_rounded,
            AppLocale.cloudSaveTitle.getString(context),
            AppLocale.neoSyncSavesSync.getString(context),
          ),
          SizedBox(height: 6.r),
          _buildInfoItem(
            context,
            Symbols.devices_rounded,
            AppLocale.crossPlatform.getString(context),
            AppLocale.crossPlatformDesc.getString(context),
          ),
          SizedBox(height: 6.r),
          _buildInfoItem(
            context,
            Symbols.security_rounded,
            AppLocale.securePrivate.getString(context),
            AppLocale.securePrivateDesc.getString(context),
          ),
          SizedBox(height: 4.r),
          Divider(
            color: theme.colorScheme.primary.withValues(alpha: 0.1),
            thickness: 1,
          ),
          RichText(
            text: TextSpan(
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 8.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
              children: [
                TextSpan(text: AppLocale.learnMoreEcosystem.getString(context)),
                TextSpan(
                  text: 'neostation.com',
                  style: TextStyle(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.bold,
                    decoration: TextDecoration.underline,
                  ),
                  recognizer: TapGestureRecognizer()
                    ..onTap = () async {
                      final url = Uri.parse('https://neogamelab.com');
                      if (await canLaunchUrl(url)) {
                        await launchUrl(url);
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

  Widget _buildInfoItem(
    BuildContext context,
    IconData icon,
    String title,
    String description,
  ) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          size: 12.r,
          color: theme.colorScheme.primary.withValues(alpha: 0.7),
        ),
        SizedBox(width: 6.r),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 8.r,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              Text(
                description,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 8.r,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
                softWrap: true,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _UpgradeModalDialog extends StatefulWidget {
  final List<PlanInfo> plans;
  final Function(String, String) onUpgrade;
  final Function() onCancel;
  final IconData Function(String) getPlanIcon;

  const _UpgradeModalDialog({
    required this.plans,
    required this.onUpgrade,
    required this.onCancel,
    required this.getPlanIcon,
  });

  @override
  State<_UpgradeModalDialog> createState() => _UpgradeModalDialogState();
}

class _UpgradeModalDialogState extends State<_UpgradeModalDialog> {
  late GamepadNavigation _gamepadNav;
  List<PlanInfo> _plans = [];
  bool _plansLoading = true;
  String? _errorMessage;
  int _selectedPlanIndex = 0;

  void _navigatePlanLeft() {
    final availablePlans = _plans.where((plan) => plan.name != 'free').toList();
    if (availablePlans.isNotEmpty) {
      setState(() {
        _selectedPlanIndex = _selectedPlanIndex > 0
            ? _selectedPlanIndex - 1
            : availablePlans.length - 1;
      });
    }
  }

  void _navigatePlanRight() {
    final availablePlans = _plans.where((plan) => plan.name != 'free').toList();
    if (availablePlans.isNotEmpty) {
      setState(() {
        _selectedPlanIndex = (_selectedPlanIndex + 1) % availablePlans.length;
      });
    }
  }

  void _selectCurrentPlan() {
    final availablePlans = _plans.where((plan) => plan.name != 'free').toList();
    if (availablePlans.isNotEmpty &&
        _selectedPlanIndex < availablePlans.length) {
      final selectedPlan = availablePlans[_selectedPlanIndex];
      final authService = Provider.of<AuthService>(context, listen: false);
      final user = authService.currentUser;
      final isCurrentPlan = user?.plan == selectedPlan.name;

      if (isCurrentPlan) {
        // Cerrar modal primero, luego mostrar dialog de cancelación

        Navigator.of(context).pop();

        // Pequeño delay para asegurar que el modal se cierre completamente
        Future.delayed(Duration(milliseconds: 100), () {
          widget.onCancel();
        });
      } else {
        // Cerrar modal primero, luego hacer upgrade
        Navigator.of(context).pop();
        widget.onUpgrade(selectedPlan.name, 'monthly');
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onNavigateLeft: (isRepeat) => _navigatePlanLeft(),
      onNavigateRight: (isRepeat) => _navigatePlanRight(),
      onSelectItem: _selectCurrentPlan,
      onBack: () {
        if (mounted) Navigator.of(context).pop();
      },
      // No incluir onNavigateUp/onNavigateDown para desactivarlos
    );
    _loadPlans();

    // Inicializar inmediatamente
    _gamepadNav.initialize();
    _gamepadNav.activate();
  }

  @override
  void dispose() {
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
          const planOrder = ['free', 'micro', 'mini', 'mega', 'ultra'];
          _plans.sort((a, b) {
            final aIndex = planOrder.indexOf(a.name);
            final bIndex = planOrder.indexOf(b.name);
            final aOrder = aIndex == -1 ? planOrder.length : aIndex;
            final bOrder = bIndex == -1 ? planOrder.length : bIndex;
            return aOrder.compareTo(bOrder);
          });

          // Inicializar selectedPlanIndex para empezar en el primer plan disponible (no free)
          final availablePlans = _plans
              .where((plan) => plan.name != 'free')
              .toList();
          if (availablePlans.isNotEmpty) {
            _selectedPlanIndex = 0;
          }
        } else {
          _errorMessage = result['message'];
        }
      });
    }
  }

  bool _isUpgrade(String? currentPlan, String targetPlan) {
    if (currentPlan == null ||
        currentPlan.isEmpty ||
        currentPlan.toLowerCase().trim() == 'free') {
      return true;
    }

    const planOrder = ['free', 'micro', 'mini', 'mega', 'ultra'];
    final current = currentPlan.toLowerCase().trim();
    final target = targetPlan.toLowerCase().trim();

    int currentIndex = -1;
    int targetIndex = -1;

    for (int i = 0; i < planOrder.length; i++) {
      if (current.contains(planOrder[i])) currentIndex = i;
      if (target.contains(planOrder[i])) targetIndex = i;
    }

    if (currentIndex == -1) return true;
    if (targetIndex == -1) {
      return false; // If target is unknown, assume it's not an upgrade
    }

    return targetIndex > currentIndex;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final authService = Provider.of<AuthService>(context, listen: false);
    final user = authService.currentUser;

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: Container(
        width: MediaQuery.of(context).size.width,
        constraints: BoxConstraints(
          maxWidth: 760.r,
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(12.r),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.15),
            width: 1.r,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12.r),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header with gradient background
              Container(
                padding: EdgeInsets.all(8.r),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.1),
                  border: Border(
                    bottom: BorderSide(
                      color: theme.colorScheme.outline.withValues(alpha: 0.2),
                      width: 1.r,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    SizedBox(width: 8.r),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            AppLocale.manageYourPlan
                                .getString(context)
                                .replaceFirst(
                                  '{plan}',
                                  user?.plan != null
                                      ? user!.plan.toUpperCase()
                                      : '',
                                ),
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onSurface,
                              fontSize: 12.r,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            AppLocale.choosePerfectPlan.getString(context),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.7,
                              ),
                              fontSize: 9.r,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: Icon(
                        Symbols.close_rounded,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.6,
                        ),
                        size: 16.r,
                      ),
                      style: IconButton.styleFrom(
                        backgroundColor: theme.colorScheme.surface.withValues(
                          alpha: 0.1,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12.r),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Content area
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(12.r),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_errorMessage != null)
                        Container(
                          padding: EdgeInsets.all(12.r),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.error.withValues(
                              alpha: 0.1,
                            ),
                            borderRadius: BorderRadius.circular(16.r),
                            border: Border.all(
                              color: theme.colorScheme.error.withValues(
                                alpha: 0.3,
                              ),
                              width: 1.r,
                            ),
                          ),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Symbols.error_outline_rounded,
                                    color: theme.colorScheme.error,
                                    size: 24.r,
                                  ),
                                  SizedBox(width: 12.r),
                                  Expanded(
                                    child: Text(
                                      _errorMessage!,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            color: theme.colorScheme.error,
                                            fontWeight: FontWeight.w500,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: 8.r),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  onPressed: _loadPlans,
                                  icon: Icon(Symbols.refresh_rounded),
                                  label: Text(
                                    AppLocale.retry.getString(context),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: theme.colorScheme.primary,
                                    foregroundColor:
                                        theme.colorScheme.onPrimary,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12.r),
                                    ),
                                    padding: EdgeInsets.symmetric(
                                      vertical: 12.r,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      else if (_plansLoading)
                        SizedBox(
                          height: 300.r,
                          child: Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  padding: EdgeInsets.all(12.r),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primary.withValues(
                                      alpha: 0.1,
                                    ),
                                    borderRadius: BorderRadius.circular(20.r),
                                  ),
                                  child: CircularProgressIndicator(
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      theme.colorScheme.primary,
                                    ),
                                  ),
                                ),
                                SizedBox(height: 8.r),
                                Text(
                                  AppLocale.loadingPlans.getString(context),
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.7),
                                    fontWeight: FontWeight.w500,
                                    fontSize: 12.r,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      else if (_plans.isEmpty && !_plansLoading)
                        SizedBox(
                          height: 300.r,
                          child: Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  padding: EdgeInsets.all(12.r),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.surface.withValues(
                                      alpha: 0.5,
                                    ),
                                    borderRadius: BorderRadius.circular(20.r),
                                  ),
                                  child: Icon(
                                    Symbols.payment_rounded,
                                    size: 48.r,
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.5),
                                  ),
                                ),
                                SizedBox(height: 8.r),
                                Text(
                                  AppLocale.noPlansAvailable.getString(context),
                                  style: theme.textTheme.headlineSmall
                                      ?.copyWith(
                                        color: theme.colorScheme.onSurface
                                            .withValues(alpha: 0.7),
                                        fontWeight: FontWeight.w500,
                                        fontSize: 12.r,
                                      ),
                                ),
                                SizedBox(height: 8.r),
                                Text(
                                  AppLocale.checkBackLater.getString(context),
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.5),
                                    fontSize: 10.r,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                SizedBox(height: 8.r),
                                ElevatedButton.icon(
                                  onPressed: _loadPlans,
                                  icon: Icon(Symbols.refresh_rounded),
                                  label: Text(
                                    AppLocale.retry.getString(context),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: theme.colorScheme.primary,
                                    foregroundColor:
                                        theme.colorScheme.onPrimary,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      else
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Plans grid
                            GridView.count(
                              crossAxisCount: 4,
                              crossAxisSpacing: 12.r,
                              mainAxisSpacing: 12.r,
                              childAspectRatio: 0.9,
                              shrinkWrap: true,
                              physics: NeverScrollableScrollPhysics(),
                              children: _plans.where((plan) => plan.name != 'free').toList().asMap().entries.map((
                                entry,
                              ) {
                                final index = entry.key;
                                final plan = entry.value;
                                final isCurrentPlan = user?.plan == plan.name;
                                final isSelectedPlan =
                                    index == _selectedPlanIndex;

                                return Container(
                                  decoration: BoxDecoration(
                                    color: isSelectedPlan
                                        ? theme.colorScheme.secondary
                                              .withValues(alpha: 0.08)
                                        : isCurrentPlan
                                        ? theme.colorScheme.primary.withValues(
                                            alpha: 0.08,
                                          )
                                        : theme.cardColor,
                                    borderRadius: BorderRadius.circular(12.r),
                                    border: Border.all(
                                      color: isSelectedPlan
                                          ? theme.colorScheme.secondary
                                                .withValues(alpha: 0.8)
                                          : isCurrentPlan
                                          ? theme.colorScheme.primary
                                                .withValues(alpha: 0.5)
                                          : theme.colorScheme.primary
                                                .withValues(alpha: 0.15),
                                      width: (isCurrentPlan || isSelectedPlan)
                                          ? 2.r
                                          : 1.r,
                                    ),
                                  ),
                                  child: Stack(
                                    children: [
                                      // Current plan badge
                                      if (isCurrentPlan)
                                        Positioned(
                                          top: 8.r,
                                          right: 8.r,
                                          child: Container(
                                            padding: EdgeInsets.symmetric(
                                              horizontal: 6.r,
                                              vertical: 3.r,
                                            ),
                                            decoration: BoxDecoration(
                                              color: theme.colorScheme.primary,
                                              borderRadius:
                                                  BorderRadius.circular(6.r),
                                            ),
                                            child: Text(
                                              AppLocale.currentBadge.getString(
                                                context,
                                              ),
                                              style: theme.textTheme.labelSmall
                                                  ?.copyWith(
                                                    color: theme
                                                        .colorScheme
                                                        .onPrimary,
                                                    fontWeight: FontWeight.w900,
                                                    fontSize: 6.r,
                                                    letterSpacing: 0.5.r,
                                                  ),
                                            ),
                                          ),
                                        ),

                                      Padding(
                                        padding: EdgeInsets.all(10.r),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            // Plan name and icon
                                            Row(
                                              children: [
                                                Container(
                                                  padding: EdgeInsets.all(5.r),
                                                  decoration: BoxDecoration(
                                                    color: theme
                                                        .colorScheme
                                                        .primary
                                                        .withValues(alpha: 0.1),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          8.r,
                                                        ),
                                                  ),
                                                  child: Icon(
                                                    widget.getPlanIcon(
                                                      plan.name,
                                                    ),
                                                    color: theme
                                                        .colorScheme
                                                        .primary,
                                                    size: 14.r,
                                                  ),
                                                ),
                                                SizedBox(width: 6.r),
                                                Expanded(
                                                  child: Text(
                                                    plan.displayName,
                                                    style: theme
                                                        .textTheme
                                                        .titleSmall
                                                        ?.copyWith(
                                                          fontWeight:
                                                              FontWeight.bold,
                                                          color: theme
                                                              .colorScheme
                                                              .onSurface,
                                                          fontSize: 10.r,
                                                        ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                              ],
                                            ),

                                            SizedBox(height: 10.r),

                                            Row(
                                              children: [
                                                Icon(
                                                  Symbols.cloud_rounded,
                                                  size: 10.r,
                                                  color: theme
                                                      .colorScheme
                                                      .primary
                                                      .withValues(alpha: 0.7),
                                                ),
                                                SizedBox(width: 4.r),
                                                Text(
                                                  plan.storageQuotaFormatted,
                                                  style: theme
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(
                                                        fontWeight:
                                                            FontWeight.w600,
                                                        color: theme
                                                            .colorScheme
                                                            .onSurface
                                                            .withValues(
                                                              alpha: 0.8,
                                                            ),
                                                        fontSize: 9.r,
                                                      ),
                                                ),
                                              ],
                                            ),
                                            Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  '\$${plan.priceMonthly.toStringAsFixed(2)}',
                                                  style: theme
                                                      .textTheme
                                                      .titleMedium
                                                      ?.copyWith(
                                                        fontWeight:
                                                            FontWeight.bold,
                                                        color: theme
                                                            .colorScheme
                                                            .onSurface,
                                                        fontSize: 14.r,
                                                      ),
                                                ),
                                                Text(
                                                  AppLocale.monthly.getString(
                                                    context,
                                                  ),
                                                  style: theme
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(
                                                        color: theme
                                                            .colorScheme
                                                            .onSurface
                                                            .withValues(
                                                              alpha: 0.5,
                                                            ),
                                                        fontSize: 8.r,
                                                      ),
                                                ),
                                                SizedBox(height: 2.r),
                                                Text(
                                                  '\$${plan.priceYearly.toStringAsFixed(2)}/${AppLocale.yearly.getString(context)}',
                                                  style: theme
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(
                                                        color: theme
                                                            .colorScheme
                                                            .primary,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                        fontSize: 8.r,
                                                      ),
                                                ),
                                              ],
                                            ),

                                            SizedBox(height: 6.r),

                                            Spacer(),

                                            // Action buttons
                                            if (!isCurrentPlan) ...[
                                              SizedBox(
                                                width: double.infinity,
                                                child: ElevatedButton.icon(
                                                  onPressed: () {
                                                    Navigator.of(context).pop();
                                                    widget.onUpgrade(
                                                      plan.name,
                                                      'monthly',
                                                    );
                                                  },
                                                  icon: Image.asset(
                                                    'assets/images/gamepad/Xbox_A_button.png',
                                                    width: 18.r,
                                                    height: 18.r,
                                                    color: theme
                                                        .colorScheme
                                                        .onPrimary,
                                                  ),
                                                  label: Text(
                                                    _isUpgrade(
                                                          user?.plan,
                                                          plan.name,
                                                        )
                                                        ? AppLocale.upgrade
                                                              .getString(
                                                                context,
                                                              )
                                                        : AppLocale.downgrade
                                                              .getString(
                                                                context,
                                                              ),
                                                    style: TextStyle(
                                                      fontWeight:
                                                          FontWeight.w400,
                                                      fontSize: 10.r,
                                                    ),
                                                  ),
                                                  style: ElevatedButton.styleFrom(
                                                    backgroundColor: theme
                                                        .colorScheme
                                                        .primary,
                                                    foregroundColor: theme
                                                        .colorScheme
                                                        .onPrimary,
                                                    shape: RoundedRectangleBorder(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            8.r,
                                                          ),
                                                    ),
                                                    padding:
                                                        EdgeInsets.symmetric(
                                                          vertical: 6.r,
                                                        ),
                                                    elevation: 0,
                                                  ),
                                                ),
                                              ),
                                            ] else ...[
                                              // Check if subscription is canceling
                                              if (user?.stripeSubscriptionStatus ==
                                                  'canceling') ...[
                                                // Show "Ends on" for canceling subscriptions
                                                Container(
                                                  width: double.infinity,
                                                  padding: EdgeInsets.symmetric(
                                                    vertical: 4.r,
                                                  ),
                                                  child: Column(
                                                    children: [
                                                      Text(
                                                        AppLocale
                                                            .subscriptionEnding
                                                            .getString(context),
                                                        style: theme
                                                            .textTheme
                                                            .bodySmall
                                                            ?.copyWith(
                                                              color: theme
                                                                  .colorScheme
                                                                  .error,
                                                              fontSize: 7.r,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .bold,
                                                            ),
                                                        textAlign:
                                                            TextAlign.center,
                                                      ),
                                                      SizedBox(height: 2.r),
                                                      Text(
                                                        AppLocale.endsOn
                                                            .getString(context)
                                                            .replaceFirst(
                                                              '{date}',
                                                              user?.subscriptionEndDateFormatted ??
                                                                  'N/A',
                                                            ),
                                                        style: theme
                                                            .textTheme
                                                            .bodySmall
                                                            ?.copyWith(
                                                              color: theme
                                                                  .colorScheme
                                                                  .onSurface
                                                                  .withValues(
                                                                    alpha: 0.7,
                                                                  ),
                                                              fontSize: 6.r,
                                                            ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ] else ...[
                                                // Show "Renews on" for active subscriptions
                                                Container(
                                                  width: double.infinity,
                                                  padding: EdgeInsets.symmetric(
                                                    vertical: 4.r,
                                                  ),
                                                  child: Text(
                                                    AppLocale.renewsOn
                                                        .getString(context)
                                                        .replaceFirst(
                                                          '{date}',
                                                          user?.subscriptionEndDateFormatted ??
                                                              'N/A',
                                                        ),
                                                    style: theme
                                                        .textTheme
                                                        .bodySmall
                                                        ?.copyWith(
                                                          color: theme
                                                              .colorScheme
                                                              .onSurface
                                                              .withValues(
                                                                alpha: 0.7,
                                                              ),
                                                          fontSize: 7.r,
                                                          fontWeight:
                                                              FontWeight.w500,
                                                        ),
                                                    textAlign: TextAlign.center,
                                                  ),
                                                ),
                                                SizedBox(
                                                  width: double.infinity,
                                                  child: OutlinedButton.icon(
                                                    onPressed: () {
                                                      Navigator.of(
                                                        context,
                                                      ).pop();
                                                      widget.onCancel();
                                                    },
                                                    icon: Image.asset(
                                                      'assets/images/gamepad/Xbox_A_button.png',
                                                      width: 16.r,
                                                      height: 16.r,
                                                      color: theme
                                                          .colorScheme
                                                          .error,
                                                    ),
                                                    label: Text(
                                                      AppLocale.endSubscription
                                                          .getString(context),
                                                      style: TextStyle(
                                                        fontWeight:
                                                            FontWeight.w600,
                                                        fontSize: 9.r,
                                                      ),
                                                    ),
                                                    style: OutlinedButton.styleFrom(
                                                      side: BorderSide(
                                                        color: theme
                                                            .colorScheme
                                                            .error
                                                            .withValues(
                                                              alpha: 0.5,
                                                            ),
                                                        width: 1.r,
                                                      ),
                                                      foregroundColor: theme
                                                          .colorScheme
                                                          .error,
                                                      shape: RoundedRectangleBorder(
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8.r,
                                                            ),
                                                      ),
                                                      padding:
                                                          EdgeInsets.symmetric(
                                                            vertical: 4.r,
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }).toList(),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),

              // Footer with Back button for gamepad
              Container(
                padding: EdgeInsets.all(8.r),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withValues(alpha: 0.8),
                  border: Border(
                    top: BorderSide(
                      color: theme.colorScheme.outline.withValues(alpha: 0.2),
                      width: 1.r,
                    ),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: Icon(Symbols.arrow_back_rounded, size: 16.r),
                      label: Text(
                        AppLocale.backWithB.getString(context),
                        style: TextStyle(fontSize: 10.r),
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.onSurface.withValues(
                          alpha: 0.7,
                        ),
                        padding: EdgeInsets.symmetric(
                          horizontal: 12.r,
                          vertical: 8.r,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Cancel Subscription Dialog with Gamepad Navigation
class _CancelSubscriptionDialog extends StatefulWidget {
  final VoidCallback onKeepSubscription;
  final VoidCallback onCancelSubscription;

  const _CancelSubscriptionDialog({
    required this.onKeepSubscription,
    required this.onCancelSubscription,
  });

  @override
  State<_CancelSubscriptionDialog> createState() =>
      _CancelSubscriptionDialogState();
}

class _CancelSubscriptionDialogState extends State<_CancelSubscriptionDialog> {
  late GamepadNavigation _gamepadNav;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onSelectItem: () {
        widget.onCancelSubscription();
      },
      onBack: () {
        widget.onKeepSubscription();
      },
    );
    _gamepadNav.initialize();
    _gamepadNav.activate();
  }

  @override
  void dispose() {
    _gamepadNav.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      backgroundColor: theme.colorScheme.surface,
      surfaceTintColor: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16.r)),
      title: Row(
        children: [
          Icon(
            Symbols.cancel_rounded,
            color: theme.colorScheme.error,
            size: 24.r,
          ),
          SizedBox(width: 12.r),
          Text(
            AppLocale.cancelSubscription.getString(context),
            style: TextStyle(
              fontSize: 18.r,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppLocale.cancelSubscriptionConfirm.getString(context),
            style: TextStyle(
              fontSize: 14.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
              height: 1.4,
            ),
          ),
        ],
      ),
      actions: [
        TextButton.icon(
          onPressed: widget.onKeepSubscription,
          icon: Image.asset(
            'assets/images/gamepad/Xbox_B_button.png',
            width: 16.r,
            height: 16.r,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
          ),
          label: Text(
            AppLocale.keepSubscription.getString(context),
            style: TextStyle(
              fontSize: 14.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          style: TextButton.styleFrom(
            padding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 8.r),
          ),
        ),
        TextButton.icon(
          onPressed: widget.onCancelSubscription,
          icon: Image.asset(
            'assets/images/gamepad/Xbox_A_button.png',
            width: 16.r,
            height: 16.r,
            color: theme.colorScheme.error,
          ),
          label: Text(
            AppLocale.cancelSubscription.getString(context),
            style: TextStyle(
              fontSize: 14.r,
              color: theme.colorScheme.error,
              fontWeight: FontWeight.w600,
            ),
          ),
          style: TextButton.styleFrom(
            padding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 8.r),
          ),
        ),
      ],
      actionsPadding: EdgeInsets.only(
        left: 16.r,
        right: 16.r,
        bottom: 16.r,
        top: 8.r,
      ),
    );
  }
}

// Delete Cloud Save Dialog with Gamepad Navigation
class _DeleteCloudSaveDialog extends StatefulWidget {
  final NeoSyncFile file;
  final Function(bool) onDisableNeoSyncChanged;

  const _DeleteCloudSaveDialog({
    required this.file,
    required this.onDisableNeoSyncChanged,
  });

  @override
  State<_DeleteCloudSaveDialog> createState() => _DeleteCloudSaveDialogState();
}

class _DeleteCloudSaveDialogState extends State<_DeleteCloudSaveDialog> {
  late GamepadNavigation _gamepadNav;
  bool disableNeoSync = false;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onSelectItem: () {
        widget.onDisableNeoSyncChanged(disableNeoSync);
        Navigator.of(context).pop(true);
      },
      onBack: () {
        Navigator.of(context).pop(false);
      },
    );
    _gamepadNav.initialize();
    _gamepadNav.activate();
  }

  @override
  void dispose() {
    _gamepadNav.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      surfaceTintColor: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.r)),
      title: Row(
        children: [
          Icon(
            Symbols.delete_forever_rounded,
            color: Theme.of(context).colorScheme.error,
            size: 18.r,
          ),
          SizedBox(width: 8.r),
          Text(
            AppLocale.deleteCloudSave.getString(context),
            style: TextStyle(
              fontSize: 15.r,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppLocale.deleteCloudSaveConfirm.getString(context),
            style: TextStyle(
              fontSize: 12.r,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.9),
              height: 1.3,
            ),
          ),
          SizedBox(height: 6.r),
          Container(
            padding: EdgeInsets.all(8.r),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(6.r),
              border: Border.all(
                color: Theme.of(
                  context,
                ).colorScheme.outline.withValues(alpha: 0.1),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Symbols.save_rounded,
                  color: Theme.of(context).colorScheme.primary,
                  size: 16.r,
                ),
                SizedBox(width: 6.r),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.file.fileName,
                        style: TextStyle(
                          fontSize: 11.r,
                          fontWeight: FontWeight.w500,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      SizedBox(height: 1.r),
                      Text(
                        '${widget.file.fileSizeFormatted} • ${widget.file.uploadedAt.toLocal().toString().split(' ')[0]}',
                        style: TextStyle(
                          fontSize: 9.r,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: 10.r),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.secondaryContainer.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(6.r),
              border: Border.all(
                color: Theme.of(
                  context,
                ).colorScheme.secondary.withValues(alpha: 0.2),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Transform.scale(
                  scale: 0.7,
                  child: Switch(
                    value: disableNeoSync,
                    onChanged: (value) {
                      setState(() {
                        disableNeoSync = value;
                      });
                      widget.onDisableNeoSyncChanged(value);
                    },
                    activeThumbColor: Theme.of(context).colorScheme.secondary,
                    activeTrackColor: Theme.of(
                      context,
                    ).colorScheme.secondary.withValues(alpha: 0.3),
                  ),
                ),
                SizedBox(width: 4.r),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppLocale.alsoDisableNeoSync.getString(context),
                        style: TextStyle(
                          fontSize: 12.r,
                          fontWeight: FontWeight.w500,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      SizedBox(height: 2.r),
                      Text(
                        AppLocale.preventsAutoSaves.getString(context),
                        style: TextStyle(
                          fontSize: 10.r,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.7),
                          height: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: 8.h),
        ],
      ),
      actionsPadding: EdgeInsets.only(right: 12.r, bottom: 12.r),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          style: TextButton.styleFrom(
            padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/images/gamepad/Xbox_B_button.png',
                width: 14.r,
                height: 14.r,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
              SizedBox(width: 6.r),
              Text(
                AppLocale.cancel.getString(context),
                style: TextStyle(
                  fontSize: 12.r,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
        ElevatedButton(
          autofocus: true,
          onPressed: () {
            widget.onDisableNeoSyncChanged(disableNeoSync);
            Navigator.of(context).pop(true);
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
            elevation: 0,
            padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8.r),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/images/gamepad/Xbox_A_button.png',
                width: 14.r,
                height: 14.r,
                color: Theme.of(context).colorScheme.onError,
              ),
              SizedBox(width: 6.r),
              Text(
                AppLocale.delete.getString(context),
                style: TextStyle(
                  fontSize: 12.r,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onError,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// Success Dialog with Gamepad Navigation
class _SuccessDialog extends StatefulWidget {
  final String title;
  final String message;
  final VoidCallback onClose;

  const _SuccessDialog({
    required this.title,
    required this.message,
    required this.onClose,
  });

  @override
  State<_SuccessDialog> createState() => _SuccessDialogState();
}

class _SuccessDialogState extends State<_SuccessDialog> {
  late GamepadNavigation _gamepadNav;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onSelectItem: widget.onClose,
      onBack: widget.onClose,
    );
    _gamepadNav.initialize();
    _gamepadNav.activate();
  }

  @override
  void dispose() {
    _gamepadNav.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      backgroundColor: theme.colorScheme.surface,
      surfaceTintColor: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16.r)),
      title: Row(
        children: [
          Icon(Symbols.check_circle_rounded, color: Colors.green, size: 24.r),
          SizedBox(width: 12.r),
          Text(
            widget.title,
            style: TextStyle(
              fontSize: 18.r,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.message,
            style: TextStyle(
              fontSize: 14.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
              height: 1.4,
            ),
          ),
        ],
      ),
      actions: [
        ElevatedButton(
          autofocus: true,
          onPressed: widget.onClose,
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.colorScheme.primary,
            foregroundColor: theme.colorScheme.onPrimary,
            elevation: 0,
            padding: EdgeInsets.symmetric(horizontal: 24.r, vertical: 12.r),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8.r),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/images/gamepad/Xbox_A_button.png',
                width: 16.r,
                height: 16.r,
                color: theme.colorScheme.onPrimary,
              ),
              SizedBox(width: 8.r),
              Text(
                AppLocale.ok.getString(context),
                style: TextStyle(fontSize: 14.r, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ],
      actionsPadding: EdgeInsets.only(
        left: 16.r,
        right: 16.r,
        bottom: 16.r,
        top: 8.r,
      ),
    );
  }
}

// Error Dialog with Gamepad Navigation
class _ErrorDialog extends StatefulWidget {
  final String title;
  final String message;
  final VoidCallback onClose;

  const _ErrorDialog({
    required this.title,
    required this.message,
    required this.onClose,
  });

  @override
  State<_ErrorDialog> createState() => _ErrorDialogState();
}

class _ErrorDialogState extends State<_ErrorDialog> {
  late GamepadNavigation _gamepadNav;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onSelectItem: widget.onClose,
      onBack: widget.onClose,
    );
    _gamepadNav.initialize();
    _gamepadNav.activate();
  }

  @override
  void dispose() {
    _gamepadNav.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      backgroundColor: theme.colorScheme.surface,
      surfaceTintColor: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16.r)),
      title: Row(
        children: [
          Icon(Symbols.error_rounded, color: theme.colorScheme.error, size: 24.r),
          SizedBox(width: 12.r),
          Text(
            widget.title,
            style: TextStyle(
              fontSize: 18.r,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.message,
            style: TextStyle(
              fontSize: 14.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
              height: 1.4,
            ),
          ),
        ],
      ),
      actions: [
        ElevatedButton(
          autofocus: true,
          onPressed: widget.onClose,
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.colorScheme.primary,
            foregroundColor: theme.colorScheme.onPrimary,
            elevation: 0,
            padding: EdgeInsets.symmetric(horizontal: 24.r, vertical: 12.r),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8.r),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/images/gamepad/Xbox_A_button.png',
                width: 16.r,
                height: 16.r,
                color: theme.colorScheme.onPrimary,
              ),
              SizedBox(width: 8.r),
              Text(
                AppLocale.ok.getString(context),
                style: TextStyle(fontSize: 14.r, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ],
      actionsPadding: EdgeInsets.only(
        left: 16.r,
        right: 16.r,
        bottom: 16.r,
        top: 8.r,
      ),
    );
  }
}

class OnlineSavesListView extends StatefulWidget {
  final List<NeoSyncFile> files;
  final int selectedIndex;
  final Function(NeoSyncFile, int) onDeleteRequest;
  final Function(int) onSelectionChanged;
  final bool isNavigatingFast;

  const OnlineSavesListView({
    super.key,
    required this.files,
    required this.selectedIndex,
    required this.onDeleteRequest,
    required this.onSelectionChanged,
    this.isNavigatingFast = false,
  });

  @override
  State<OnlineSavesListView> createState() => OnlineSavesListViewState();
}

class OnlineSavesListViewState extends State<OnlineSavesListView>
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

    // Initialize scroll controller after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _centeredScrollController.initialize(
          context: context,
          initialIndex: widget.selectedIndex,
          totalItems: widget.files.length,
        );
        // Force scroll to index 0 on initial load to ensure highlight appears
        _centeredScrollController.scrollToIndex(
          widget.selectedIndex,
          immediate: true,
        );
      }
    });
  }

  @override
  void didUpdateWidget(OnlineSavesListView oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.files.length != widget.files.length) {
      _centeredScrollController.updateTotalItems(widget.files.length);
    }

    if (oldWidget.selectedIndex != widget.selectedIndex) {
      // Ajustar duraciones dinámicamente según el modo de navegación (NeoHold v2)
      final animationDuration = widget.isNavigatingFast
          ? const Duration(milliseconds: 120)
          : const Duration(milliseconds: 250);

      final scrollDuration = widget.isNavigatingFast
          ? const Duration(milliseconds: 180)
          : const Duration(milliseconds: 360);

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

  void scrollToIndex(int index, {bool immediate = false}) {
    if (_centeredScrollController.scrollController.hasClients) {
      _centeredScrollController.scrollToIndex(index, immediate: immediate);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final double itemHeight = 40.r;
    final double marginBottom = 4.r;
    final double totalItemHeight = itemHeight + marginBottom;

    return Stack(
      children: [
        // 1. Highlight Layer
        AnimatedBuilder(
          animation: Listenable.merge([
            _selectionController,
            _centeredScrollController.scrollController,
          ]),
          builder: (context, child) {
            // Using a safe fallback for scroll offset if no clients yet
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
                  color: theme.colorScheme.secondary,
                  borderRadius: BorderRadius.circular(12.r),
                ),
              ),
            );
          },
        ),
        // 2. List Layer
        ValueListenableBuilder<int>(
          valueListenable: _centeredScrollController.rebuildNotifier,
          builder: (context, rebuildCount, _) {
            return ListView.builder(
              key: ValueKey('online_saves_list_$rebuildCount'),
              controller: _centeredScrollController.scrollController,
              padding: EdgeInsets.symmetric(vertical: 4.r, horizontal: 4.w),
              itemCount: widget.files.length,
              itemBuilder: (context, index) {
                return GestureDetector(
                  onTap: () {
                    SfxService().playNavSound();
                    widget.onSelectionChanged(index);
                  },
                  child: _buildOnlineSaveItem(
                    context,
                    widget.files[index],
                    index,
                  ),
                );
              },
            );
          },
        ),
      ],
    );
  }

  Widget _buildOnlineSaveItem(
    BuildContext context,
    NeoSyncFile file,
    int index,
  ) {
    final isSelected = index == widget.selectedIndex;

    return Container(
      key: ValueKey('save_item_$index'),
      height: 40.r,
      margin: EdgeInsets.only(bottom: 4.r),
      padding: EdgeInsets.all(6.r),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: isSelected
              ? Colors.transparent
              : Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
          width: 0.5.r,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 28.r,
            height: 28.r,
            decoration: BoxDecoration(
              color: isSelected
                  ? Theme.of(
                      context,
                    ).colorScheme.onSecondary.withValues(alpha: 0.2)
                  : Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8.r),
            ),
            child: Icon(
              Symbols.save_rounded,
              color: isSelected
                  ? Theme.of(context).colorScheme.onSecondary
                  : Theme.of(context).colorScheme.primary,
              size: 16.r,
            ),
          ),
          SizedBox(width: 8.r),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  style: TextStyle(
                    fontSize: 9.r,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                    color: isSelected
                        ? Theme.of(context).colorScheme.onSecondary
                        : Theme.of(context).colorScheme.onSurface,
                    fontFamily: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.fontFamily,
                  ),
                  child: Text(
                    file.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                SizedBox(height: 1.r),
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  style: TextStyle(
                    fontSize: 8.r,
                    color: isSelected
                        ? Theme.of(
                            context,
                          ).colorScheme.onSecondary.withValues(alpha: 0.8)
                        : Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.6),
                    fontFamily: Theme.of(
                      context,
                    ).textTheme.bodySmall?.fontFamily,
                  ),
                  child: Text(
                    '${file.fileSizeFormatted} • ${file.uploadedAt.toLocal().toString().split(' ')[0]}',
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => widget.onDeleteRequest(file, index),
            icon: Icon(
              Symbols.delete_rounded,
              color: isSelected
                  ? Theme.of(context).colorScheme.onSecondary
                  : Theme.of(context).colorScheme.error,
            ),
            tooltip: AppLocale.delete.getString(context),
          ),
        ],
      ),
    );
  }
}
