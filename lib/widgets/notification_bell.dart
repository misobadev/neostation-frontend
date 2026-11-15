import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/themes/app_themes.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/utils/gamepad_nav.dart';

/// Notification bell icon that opens a dropdown with all active global
/// notifications, including their progress.
///
/// Designed to live in the top header next to the clock.
///
/// The dropdown is rendered through an [OverlayEntry] (not `showMenu`) so the
/// notification list can rebuild live without `showMenu`'s `IntrinsicWidth`
/// choking on the shrink-wrapping list viewport.
///
/// Gamepad: Select (View) opens and closes the dropdown from anywhere the
/// header is on screen, the D-pad walks the entries, A acts on the highlighted
/// one and B closes. See [_NotificationsDropdownMenuState].
class NotificationBell extends StatefulWidget {
  const NotificationBell({super.key});

  @override
  State<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends State<NotificationBell>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  late ValueNotifier<List<GlobalNotificationData>> _notifications;
  OverlayEntry? _overlayEntry;

  /// Vertical gap between the bell icon and the top of the dropdown.
  static const double _dropdownGap = 14;

  /// Inset of the dropdown from the right edge of the screen.
  static const double _dropdownRightInset = 8;

  /// Half cycles the arrival pulse runs for. Six is three round trips.
  static const int _pulseHalfCycles = 6;

  /// Notification count at the last [_syncPulse], so the pulse fires on a
  /// genuine arrival rather than on every progress update to an existing one.
  int _lastCount = 0;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 0.4).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // The pulse announces an arrival and then stops. The bell lives in the
    // header on every screen, so anything that keeps this controller running
    // requests a frame every vsync for as long as it runs. Mounting must not
    // start it: only a notification arriving while mounted does.
    _notifications = GlobalNotificationService().notifier;
    _lastCount = _notifications.value.length;
    // Tween begin (1.0 = fully opaque) sits at controller value 0.
    _pulseController.value = 0;
    _notifications.addListener(_syncPulse);

    // The bell is the only surface for notifications and it has no place in
    // any screen's own navigation order, so Select reaches it instead. The
    // hook is app-wide but yields to a screen that gives Select its own
    // meaning; see [GamepadNavigation.globalSelectTap].
    GamepadNavigation.globalSelectTap = _handleSelectTap;
  }

  /// Opens the dropdown on a Select tap, or closes it if it is already open.
  ///
  /// Ignored while another route covers the header. The bell stays mounted
  /// underneath a pushed game screen or an open dialog, so without this a
  /// Select tap there would drop a popup anchored to an off-screen bell on top
  /// of a surface that has no notification affordance at all.
  void _handleSelectTap() {
    if (!mounted) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;
    _toggleDropdown(context);
  }

  /// Pulses briefly when a notification arrives, then parks the controller at
  /// its opaque end.
  ///
  /// The pulse must be bounded. Notifications never auto-dismiss (see
  /// [GlobalNotificationService]), so pulsing for as long as the list is
  /// non-empty is in practice pulsing forever: a single "ES-DE import
  /// complete" notice — a success message no user has any reason to clear —
  /// held the app at a frame every vsync for the rest of the session, which
  /// measured 0.53 of a core and 17% of the GPU on a 3440x1440 240 Hz display.
  /// The static badge and the filled bell icon already carry the "you have
  /// notifications" signal on their own, so nothing is lost by stopping.
  void _syncPulse() {
    final int count = _notifications.value.length;
    final int previous = _lastCount;
    _lastCount = count;

    if (count == 0) {
      if (_pulseController.isAnimating) {
        _pulseController.stop();
      }
      _pulseController.value = 0;
      return;
    }

    if (count > previous) {
      // Each iteration is a half cycle, so an even count both ends on a whole
      // number of round trips and parks the controller back at 0 (opaque).
      _pulseController.repeat(reverse: true, count: _pulseHalfCycles);
    }
  }

  @override
  void dispose() {
    // Only clear the hook if it is still ours: a rebuilt header registers the
    // replacement bell before the old one is disposed.
    if (GamepadNavigation.globalSelectTap == _handleSelectTap) {
      GamepadNavigation.globalSelectTap = null;
    }
    _notifications.removeListener(_syncPulse);
    _closeDropdown();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<GlobalNotificationData>>(
      valueListenable: GlobalNotificationService().notifier,
      builder: (context, notifications, _) {
        final hasNotifications = notifications.isNotEmpty;
        return GestureDetector(
          onTap: () => _toggleDropdown(context),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // FadeTransition rather than AnimatedBuilder + Opacity: it drives
              // the opacity layer directly, so a running pulse repaints without
              // rebuilding this subtree every frame. Parked at 1.0 (opaque)
              // whenever the controller is stopped.
              FadeTransition(
                opacity: _pulseAnimation,
                child: Icon(
                  hasNotifications
                      ? Symbols.notifications_active_rounded
                      : Symbols.notifications_rounded,
                  color: hasNotifications
                      ? AppThemes.getCustomColors(context).warningColor
                      : Theme.of(context).colorScheme.onSurface,
                  size: 14.r,
                ),
              ),
              if (hasNotifications)
                Positioned(
                  top: 0,
                  right: 0,
                  child: Container(
                    width: 5.r,
                    height: 5.r,
                    decoration: BoxDecoration(
                      color: AppThemes.getCustomColors(context).warningColor,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Theme.of(context).colorScheme.surface,
                        width: 0.8.r,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  void _toggleDropdown(BuildContext context) {
    if (_overlayEntry != null) {
      _closeDropdown();
    } else {
      _openDropdown(context);
    }
  }

  void _openDropdown(BuildContext context) {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final offset = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;

    _overlayEntry = OverlayEntry(
      builder: (overlayContext) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _closeDropdown,
              ),
            ),
            Positioned(
              top: offset.dy + size.height + _dropdownGap,
              right: _dropdownRightInset,
              child: _NotificationsDropdownMenu(onClose: _closeDropdown),
            ),
          ],
        );
      },
    );
    Overlay.of(context).insert(_overlayEntry!);
  }

  void _closeDropdown() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }
}

/// One D-pad stop inside the dropdown.
///
/// "Clear all" is an entry of its own rather than a header button, because a
/// header button is unreachable with a controller and clearing the bell would
/// then be mouse-only.
class _DropdownEntry {
  /// Notification this entry acts on, or null for the "Clear all" entry.
  final String? notificationId;

  const _DropdownEntry.clearAll() : notificationId = null;
  const _DropdownEntry.notification(String id) : notificationId = id;

  bool get isClearAll => notificationId == null;
}

class _NotificationsDropdownMenu extends StatefulWidget {
  /// Closes the dropdown. B and a Select tap both route here, as does acting
  /// on the last remaining entry.
  final VoidCallback onClose;

  const _NotificationsDropdownMenu({required this.onClose});

  @override
  State<_NotificationsDropdownMenu> createState() =>
      _NotificationsDropdownMenuState();
}

class _NotificationsDropdownMenuState
    extends State<_NotificationsDropdownMenu> {
  /// Modal, so a widget mounting behind the dropdown (the systems grid when a
  /// startup scan finishes, say) is slotted underneath instead of stealing the
  /// controller while the popup is on screen.
  static const String _navLayerId = 'notification_dropdown';

  late final GamepadNavigation _gamepadNav;
  final ScrollController _scrollController = ScrollController();

  /// Row keys by notification id, so the highlighted row can be scrolled into
  /// view without guessing at row heights — messages run to six lines, so no
  /// fixed-height arithmetic would be right.
  final Map<String, GlobalKey> _rowKeys = {};

  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onNavigateUp: () => _move(-1),
      onNavigateDown: () => _move(1),
      onSelectItem: _activateSelected,
      onBack: widget.onClose,
      // Select toggles: the button that opened the popup closes it again.
      onSelectButton: widget.onClose,
      // A handful of entries that wrap; a held direction would just spin.
      allowRepeat: false,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        _navLayerId,
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
        modal: true,
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(_navLayerId);
    _gamepadNav.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// The current D-pad stops, in the order they are drawn.
  List<_DropdownEntry> _entriesFor(List<GlobalNotificationData> notifications) {
    return [
      if (notifications.any((n) => !n.ongoing)) const _DropdownEntry.clearAll(),
      for (final n in notifications) _DropdownEntry.notification(n.id),
    ];
  }

  /// Keeps the highlight on a real entry after the list changed underneath it —
  /// a task finishing removes the "Clear all" entry's reason to exist, and a
  /// dismissal shortens the list.
  int _clampedIndex(int count) {
    if (count == 0) return 0;
    return _selectedIndex.clamp(0, count - 1);
  }

  void _move(int delta) {
    final entries = _entriesFor(GlobalNotificationService().notifier.value);
    if (entries.isEmpty) return;
    final from = _clampedIndex(entries.length);
    setState(() {
      _selectedIndex = (from + delta + entries.length) % entries.length;
    });
    SfxService().playNavSound();
    _scrollSelectedIntoView();
  }

  void _scrollSelectedIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final entries = _entriesFor(GlobalNotificationService().notifier.value);
      if (entries.isEmpty) return;
      final entry = entries[_clampedIndex(entries.length)];
      if (entry.isClearAll) {
        // Outside the scroll view; showing the top of the list reads as
        // "the header is what you are on".
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            0,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
          );
        }
        return;
      }
      final rowContext = _rowKeys[entry.notificationId]?.currentContext;
      if (rowContext == null) return;
      Scrollable.ensureVisible(
        rowContext,
        alignment: 0.5,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      );
    });
  }

  /// A on the highlighted entry: the same action its on-screen control offers.
  void _activateSelected() {
    final service = GlobalNotificationService();
    final entries = _entriesFor(service.notifier.value);
    if (entries.isEmpty) return;

    final entry = entries[_clampedIndex(entries.length)];
    SfxService().playEnterSound();
    if (entry.isClearAll) {
      service.dismiss();
    } else {
      service.dismiss(entry.notificationId);
    }

    // Nothing left to look at, so don't leave an empty panel on screen.
    if (service.notifier.value.isEmpty) {
      widget.onClose();
      return;
    }
    setState(() {
      _selectedIndex = _clampedIndex(
        _entriesFor(service.notifier.value).length,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<GlobalNotificationData>>(
      valueListenable: GlobalNotificationService().notifier,
      builder: (context, notifications, _) {
        final entries = _entriesFor(notifications);
        final selected = _clampedIndex(entries.length);
        final clearAllSelected =
            entries.isNotEmpty && entries[selected].isClearAll;
        final selectedNotificationId = entries.isEmpty || clearAllSelected
            ? null
            : entries[selected].notificationId;
        return Material(
          color: Theme.of(context).colorScheme.surface,
          elevation: 6,
          shadowColor: Theme.of(context).colorScheme.shadow
              .withValues(alpha: 0.3),
          shape: RoundedRectangleBorder(
            borderRadius: CornerRadii.of(context).radiusExternal,
            side: BorderSide(
              color: Theme.of(context).colorScheme.outline
                  .withValues(alpha: 0.3),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 300.r,
              minWidth: 200.r,
              maxHeight: 360.r,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: 12.r,
                    vertical: 10.r,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        AppLocale.notifications.getString(context),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                          fontSize: 12.r,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      // Hidden when every listed notification is still
                      // tracking running work: "Clear all" leaves those alone
                      // (a scrape or an import must not lose its progress bar
                      // because the bell was tidied), so offering it there is
                      // a button that visibly does nothing.
                      if (notifications.any((n) => !n.ongoing))
                        GestureDetector(
                          onTap: () {
                            setState(() => _selectedIndex = 0);
                            _activateSelected();
                          },
                          child: Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 6.r,
                              vertical: 2.r,
                            ),
                            decoration: BoxDecoration(
                              color: clearAllSelected
                                  ? Theme.of(context).colorScheme.primary
                                        .withValues(alpha: 0.15)
                                  : Colors.transparent,
                              borderRadius: CornerRadii.of(context)
                                  .radiusInternal,
                            ),
                            child: Text(
                              AppLocale.clearAll.getString(context),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.primary,
                                fontSize: 10.r,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (notifications.isEmpty)
                  Padding(
                    padding: EdgeInsets.all(16.r),
                    child: Center(
                      child: Text(
                        AppLocale.noActiveNotifications.getString(context),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface
                              .withValues(alpha: 0.6),
                          fontSize: 11.r,
                        ),
                      ),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      controller: _scrollController,
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemCount: notifications.length,
                      separatorBuilder: (_, _) => Divider(
                        height: 1.r,
                        color: Theme.of(context).colorScheme.outline
                            .withValues(alpha: 0.2),
                      ),
                      itemBuilder: (context, index) {
                        final data = notifications[index];
                        return _NotificationDropdownItem(
                          key: _rowKeys.putIfAbsent(data.id, GlobalKey.new),
                          data: data,
                          selected: data.id == selectedNotificationId,
                          onFocus: () {
                            setState(() {
                              _selectedIndex = entries.indexWhere(
                                (e) => e.notificationId == data.id,
                              );
                            });
                          },
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _NotificationDropdownItem extends StatelessWidget {
  final GlobalNotificationData data;

  /// Whether the D-pad highlight is on this row.
  final bool selected;

  /// Moves the highlight here, so a pointer and the D-pad agree on where the
  /// cursor is instead of leaving a stale highlight elsewhere in the list.
  final VoidCallback onFocus;

  const _NotificationDropdownItem({
    super.key,
    required this.data,
    required this.selected,
    required this.onFocus,
  });

  @override
  Widget build(BuildContext context) {
    final Color iconColor;
    final IconData icon;

    switch (data.type) {
      case GlobalNotificationType.success:
        iconColor = Colors.green.shade400;
        icon = Symbols.check_circle_rounded;
      case GlobalNotificationType.error:
        iconColor = Theme.of(context).colorScheme.error;
        icon = Symbols.error_rounded;
      case GlobalNotificationType.info:
        iconColor = Theme.of(context).colorScheme.primary;
        icon = Symbols.info_rounded;
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onFocus,
      child: Container(
        color: selected
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.15)
            : Colors.transparent,
        padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 10.r),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: iconColor, size: 16.r),
            SizedBox(width: 8.r),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (data.title != null)
                    Text(
                      data.title!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontSize: 11.r,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  Text(
                    data.message,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface
                          .withValues(alpha: 0.8),
                      fontSize: 10.r,
                    ),
                    // Enough room for a message that names a path and then says
                    // what to do about it. At three lines the ROM-folder warnings
                    // were cut off mid-advice ("…came from a temporary deskt"),
                    // leaving the one actionable half of the message unread.
                    // Short notifications are unaffected: this is a maximum.
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (data.progress != null) ...[
                    SizedBox(height: 6.r),
                    LinearProgressIndicator(
                      value: data.progress,
                      minHeight: 3.r,
                      color: iconColor,
                      backgroundColor: iconColor.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(2.r),
                    ),
                  ],
                ],
              ),
            ),
            SizedBox(width: 8.r),
            GestureDetector(
              onTap: () => GlobalNotificationService().dismiss(data.id),
              child: Icon(
                Symbols.close_rounded,
                color: Theme.of(context).colorScheme.onSurface
                    .withValues(alpha: 0.5),
                size: 14.r,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
