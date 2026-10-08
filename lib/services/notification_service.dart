import 'dart:convert';
import 'dart:async';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;
import 'package:neostation/models/notification_models.dart';
import 'package:neostation/utils/app_config.dart';
import 'package:flutter/material.dart';
import 'package:neostation/widgets/plan_welcome_modal.dart';
import 'package:neostation/widgets/plan_farewell_modal.dart';
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:neostation/sync/providers/neo_sync_adapter.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/logger_service.dart';

/// Service responsible for real-time notifications via WebSockets.
///
/// Handles live updates for subscription plan changes, payment status, and
/// synchronization events. Includes automatic reconnection logic, health checks,
/// and UI integration for displaying system modals.
///
/// The socket follows the account: it opens as soon as a NeoSync user who may
/// receive notifications is signed in (at startup, or on sign-in) and closes when
/// they sign out or save sync moves to another provider. It used to open only on
/// an app resume, and only if the Sync tab had handed the service a widget
/// context it could read the account through.
class NotificationService extends ChangeNotifier {
  static const String _tokenKey = 'auth_token';
  final _log = LoggerService.instance;

  NotificationService({
    required AuthService authService,
    NeoSyncProvider? neoSyncProvider,
    BuildContext? Function()? modalContext,
    @visibleForTesting WebSocketChannel Function(Uri uri)? connectChannel,
  }) : _authService = authService,
       _neoSyncProvider = neoSyncProvider,
       _modalContext = modalContext ?? _noContext,
       _connectChannel = connectChannel ?? WebSocketChannel.connect {
    _authService.addListener(_onAccountChanged);
    SyncManager.instance.addListener(_onAccountChanged);
    // Already signed in at startup: nothing else would open the socket.
    _onAccountChanged();
  }

  final AuthService _authService;

  /// Refreshed after a plan change; null where there is no NeoSync provider.
  final NeoSyncProvider? _neoSyncProvider;

  /// A context under the app's navigator, for the plan-change modals.
  final BuildContext? Function() _modalContext;

  final WebSocketChannel Function(Uri uri) _connectChannel;

  static BuildContext? _noContext() => null;

  /// Eligibility as last seen by [_onAccountChanged]. The socket reacts to the
  /// change, not to every notification: [SyncManager] relays every provider
  /// update, and a connect that failed must not be retried on each one.
  bool _wasEligible = false;

  /// Set while the app is in the background (or the screen is off). Account
  /// changes then wait for the resume, which calls [connect] itself.
  bool _suspended = false;

  bool _disposed = false;

  /// Bumped whenever the socket is closed on purpose ([disconnect], [suspend]).
  /// A [connect] still awaiting the token or the handshake compares it after
  /// each await, so a sign-out or a screen-off that lands mid-connect isn't
  /// undone by the connect finishing afterwards.
  int _generation = 0;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  bool _isConnected = false;
  bool _isConnecting = false;
  String? _lastError;
  final List<NotificationMessage> _notifications = [];

  bool _shouldAutoReconnect = true;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 3;
  static const Duration _baseReconnectDelay = Duration(seconds: 2);
  Timer? _reconnectTimer;

  Timer? _connectionCheckTimer;
  static const Duration _connectionCheckInterval = Duration(minutes: 5);
  DateTime? _lastMessageTime;

  bool get isConnected => _isConnected;
  bool get isConnecting => _isConnecting;
  String? get lastError => _lastError;
  List<NotificationMessage> get notifications =>
      List.unmodifiable(_notifications);
  int get reconnectAttempts => _reconnectAttempts;

  void _safeNotifyListeners() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      notifyListeners();
    });
  }

  /// Opens the socket when the account becomes eligible for notifications and
  /// closes it when it stops being so (sign-out, a free plan, or save sync
  /// switched to another provider).
  void _onAccountChanged() {
    final eligible = _isUserAuthenticatedForNeoSync();
    if (eligible == _wasEligible) return;
    _wasEligible = eligible;

    if (!eligible) {
      disconnect();
    } else if (!_suspended) {
      // A new account (or provider) gets a fresh set of retries.
      _reconnectAttempts = 0;
      unawaited(connect());
    }
  }

  /// Triggers the appropriate welcome or farewell modal based on plan changes.
  void _showPlanUpdateModalImmediately(NotificationMessage notification) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _modalContext();
      if (context != null && context.mounted) {
        try {
          final currentPlan = _authService.currentUser?.plan;

          if (currentPlan != null) {
            final isUpgrade =
                notification.eventType == NotificationType.planUpgraded ||
                (notification.data['new_plan'] != null &&
                    notification.data['old_plan'] != null &&
                    _isUpgrade(
                      notification.data['old_plan'],
                      notification.data['new_plan'],
                    ));

            if (isUpgrade) {
              PlanWelcomeModal.show(context, currentPlan);
            } else {
              final oldPlan = notification.data['old_plan'];
              if (oldPlan != null) {
                PlanFarewellModal.show(context, oldPlan, currentPlan);
              }
            }
          }
        } catch (e) {
          _log.e('Error showing plan update modal: $e');
        }
      }
    });
  }

  /// Refreshes user profile and cloud synchronization data following a plan update.
  void _refreshDataOnPlanUpdate() {
    try {
      _authService.getProfile().then((_) => _safeNotifyListeners());

      _neoSyncProvider?.loadFiles().then((_) {});
      _neoSyncProvider?.loadQuota().then((_) {});
    } catch (e) {
      _log.e('Error refreshing data on plan update: $e');
    }
  }

  /// Determines if a plan change transition constitutes an upgrade.
  bool _isUpgrade(String oldPlan, String newPlan) {
    final levels = {'free': 0, 'micro': 1, 'mini': 2, 'mega': 3, 'ultra': 4};

    final oldLevel = levels[oldPlan.toLowerCase()] ?? 0;
    final newLevel = levels[newPlan.toLowerCase()] ?? 0;

    return newLevel > oldLevel;
  }

  Future<String?> _getToken() async {
    try {
      return await CredentialStore.read(_tokenKey);
    } catch (e) {
      // An unreadable store is not a signed-out user: report "no token" for
      // this call and leave the stored credential alone.
      _log.w('Could not read the NeoSync token: $e');
      return null;
    }
  }

  /// Establishes the WebSocket connection with the notification server.
  ///
  /// Authenticates using the stored JWT and initiates health monitoring and
  /// missed notification retrieval.
  ///
  /// Does nothing — and schedules no retry — while nobody eligible is signed
  /// in: there is nothing to connect as, and [_onAccountChanged] connects once
  /// there is.
  Future<void> connect() async {
    _suspended = false;
    _shouldAutoReconnect = true;
    if (_isConnected || _isConnecting) {
      return;
    }

    if (!_isUserAuthenticatedForNeoSync()) {
      return;
    }

    _isConnecting = true;
    _lastError = null;
    _safeNotifyListeners();

    final generation = _generation;
    WebSocketChannel? channel;
    try {
      final token = await _getToken();
      if (generation != _generation) return;
      if (token == null) {
        _isConnecting = false;
        _safeNotifyListeners();
        return;
      }

      final wsUrl = '${AppConfig.notifyBaseUrl}?token=$token';

      channel = _connectChannel(Uri.parse(wsUrl));
      _channel = channel;

      // Bound to this channel: a socket closed earlier can finish closing
      // after a newer one opened, and its callbacks must not touch that one.
      final current = channel;
      _subscription = channel.stream.listen(
        _onMessage,
        onError: (Object error) {
          if (identical(current, _channel)) _onError(error);
        },
        onDone: () {
          if (identical(current, _channel)) _onDisconnected();
        },
      );

      await channel.ready.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw TimeoutException('WebSocket connection timeout');
        },
      );
      if (generation != _generation) return;

      _isConnected = true;
      _isConnecting = false;
      _reconnectAttempts = 0;

      _startConnectionMonitoring();
      _requestMissedNotifications();

      _safeNotifyListeners();
    } catch (e) {
      if (generation != _generation) return;
      _isConnecting = false;
      _lastError = 'Connection failed: $e';

      _log.w('WebSocket connection failed: $e');

      _subscription?.cancel();
      _subscription = null;
      channel?.sink.close();
      _channel = null;

      if (_reconnectAttempts < _maxReconnectAttempts) {
        _scheduleReconnect();
      } else {
        _log.w('Max reconnection attempts reached, giving up');
      }

      _safeNotifyListeners();
    }
  }

  /// Terminates the WebSocket connection and disables automatic reconnection.
  void disconnect() {
    _shouldAutoReconnect = false;
    _closeChannel();

    _isConnected = false;
    _isConnecting = false;
    _stopConnectionMonitoring();
    _reconnectTimer?.cancel();
    _safeNotifyListeners();
  }

  /// Closes the WebSocket and cancels timers when the app enters background.
  /// Disables auto-reconnect to prevent background activity; [connect] re-enables it on resume.
  void suspend() {
    _log.d('NotificationService: suspended (app backgrounded)');
    _suspended = true;
    _shouldAutoReconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
    _stopConnectionMonitoring();
    _closeChannel();
    _isConnected = false;
    _isConnecting = false;
    _safeNotifyListeners();
  }

  /// Closes the socket on purpose and invalidates any [connect] in flight.
  void _closeChannel() {
    _generation++;
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close(status.normalClosure);
    _channel = null;
  }

  /// Internal handler for incoming WebSocket messages.
  ///
  /// Routes notifications, missed updates, and heartbeat (ping/pong) events.
  void _onMessage(dynamic message) {
    try {
      final data = jsonDecode(message);
      final wsMessage = WebSocketMessage.fromJson(data);

      _lastMessageTime = DateTime.now();
      _reconnectAttempts = 0;

      if (wsMessage.isNotification) {
        final notification = wsMessage.asNotification;
        if (notification != null) {
          _notifications.insert(0, notification);

          if (notification.eventType == NotificationType.planUpgraded ||
              notification.eventType == NotificationType.planChanged ||
              notification.eventType == NotificationType.planUpdated ||
              notification.eventType == NotificationType.paymentSucceeded) {
            _refreshDataOnPlanUpdate();
            _showPlanUpdateModalImmediately(notification);
            _safeNotifyListeners();
          }

          _safeNotifyListeners();
        }
      } else if (wsMessage.type == 'missed_notifications') {
        final missedNotifications =
            wsMessage.data['notifications'] as List<dynamic>? ?? [];

        for (final notificationData in missedNotifications) {
          try {
            final notification = NotificationMessage.fromJson(notificationData);

            final exists = _notifications.any((n) => n.id == notification.id);
            if (!exists) {
              _notifications.insert(0, notification);

              if (notification.eventType == NotificationType.planUpgraded ||
                  notification.eventType == NotificationType.planChanged ||
                  notification.eventType == NotificationType.planUpdated ||
                  notification.eventType == NotificationType.paymentSucceeded) {
                _refreshDataOnPlanUpdate();
                _showPlanUpdateModalImmediately(notification);
              }
            }
          } catch (e) {
            _log.e('Error processing missed notification: $e');
          }
        }

        if (missedNotifications.isNotEmpty) {
          _safeNotifyListeners();
        }
      } else if (wsMessage.isPing) {
        _sendPong();
      }
    } catch (e) {
      _log.e('Error processing WebSocket message: $e');
    }
  }

  void _onError(dynamic error) {
    _log.e('WebSocket error: $error');

    _lastError = 'WebSocket error: $error';
    _isConnected = false;
    _stopConnectionMonitoring();
    _scheduleReconnect();
    _safeNotifyListeners();
  }

  void _onDisconnected() {
    _log.w('WebSocket disconnected');

    _isConnected = false;
    _channel = null;
    _subscription = null;
    _stopConnectionMonitoring();

    _scheduleReconnect();

    _safeNotifyListeners();
  }

  /// Schedules a reconnection attempt using exponential backoff.
  void _scheduleReconnect() {
    if (!_shouldAutoReconnect || _reconnectAttempts >= _maxReconnectAttempts) {
      return;
    }

    _reconnectTimer?.cancel();
    _reconnectAttempts++;

    final delay = _baseReconnectDelay * (1 << (_reconnectAttempts - 1));

    _reconnectTimer = Timer(delay, () async {
      await connect();
    });
  }

  void _startConnectionMonitoring() {
    _stopConnectionMonitoring();
    _lastMessageTime = DateTime.now();

    _connectionCheckTimer = Timer.periodic(_connectionCheckInterval, (timer) {
      if (_isConnected && _channel != null) {
        _checkConnectionHealth();
      }
    });
  }

  void _stopConnectionMonitoring() {
    _connectionCheckTimer?.cancel();
    _connectionCheckTimer = null;
    _lastMessageTime = null;
  }

  /// Verifies connection vitality by checking the time since the last received message.
  ///
  /// If the connection appears stale, it triggers a request for missed
  /// notifications as a health probe.
  void _checkConnectionHealth() {
    if (_lastMessageTime != null) {
      final timeSinceLastMessage = DateTime.now().difference(_lastMessageTime!);

      if (timeSinceLastMessage > Duration(minutes: 10)) {
        try {
          _requestMissedNotifications();
        } catch (e) {
          _log.e('Connection health check failed: $e');
          _onDisconnected();
        }
      }
    }
  }

  /// Sends a 'pong' heartbeat response to the server.
  void _sendPong() {
    if (_channel != null && _isConnected) {
      final pongMessage = WebSocketMessage(type: 'pong', data: {});
      _channel!.sink.add(jsonEncode(pongMessage.toJson()));
    }
  }

  /// Requests any notifications that occurred while the client was disconnected.
  void _requestMissedNotifications() {
    if (_channel != null && _isConnected) {
      try {
        final requestMessage = WebSocketMessage(
          type: 'get_missed_notifications',
          data: {},
        );
        _channel!.sink.add(jsonEncode(requestMessage.toJson()));
      } catch (e) {
        _log.e('Error requesting missed notifications: $e');
      }
    }
  }

  /// Marks a specific notification as read in the local state.
  void markNotificationAsRead(String notificationId) {
    final index = _notifications.indexWhere((n) => n.id == notificationId);
    if (index != -1) {
      _notifications[index] = NotificationMessage(
        id: _notifications[index].id,
        userId: _notifications[index].userId,
        eventType: _notifications[index].eventType,
        message: _notifications[index].message,
        data: _notifications[index].data,
        receivedAt: _notifications[index].receivedAt,
        isRead: true,
      );
      _safeNotifyListeners();
    }
  }

  /// Clears the local notification list.
  void clearNotifications() {
    _notifications.clear();
    _safeNotifyListeners();
  }

  /// Returns the count of unread notifications.
  int get unreadCount {
    return _notifications.where((n) => !n.isRead).length;
  }

  /// Retrieves a list of unread notifications.
  List<NotificationMessage> getUnreadNotifications() {
    return _notifications.where((n) => !n.isRead).toList();
  }

  /// Filters notifications by their event type.
  List<NotificationMessage> getNotificationsByType(NotificationType type) {
    return _notifications.where((n) => n.eventType == type).toList();
  }

  /// Resets the last recorded error state.
  void clearError() {
    _lastError = null;
    _reconnectAttempts = 0;
    _safeNotifyListeners();
  }

  /// Manually triggers a reconnection attempt.
  Future<void> retryConnection() async {
    _lastError = null;
    _reconnectAttempts = 0;
    _shouldAutoReconnect = true;
    await connect();
  }

  /// Validates that the current user has the necessary credentials and plan
  /// level to access real-time notifications.
  bool _isUserAuthenticatedForNeoSync() {
    try {
      // Notifications are NeoSync-specific.
      final syncProvider = SyncManager.instance.active;
      if (syncProvider == null ||
          syncProvider.providerId != NeoSyncAdapter.kProviderId ||
          !syncProvider.isAuthenticated) {
        return false;
      }

      if (!_authService.isLoggedIn) {
        return false;
      }

      final user = _authService.currentUser;
      if (user == null || !user.emailVerified) {
        return false;
      }

      if (user.plan.toLowerCase() == 'free') {
        return false;
      }

      return true;
    } catch (e) {
      _log.e('Error checking NeoSync authentication: $e');
      return false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _authService.removeListener(_onAccountChanged);
    SyncManager.instance.removeListener(_onAccountChanged);
    _shouldAutoReconnect = false;
    disconnect();
    _reconnectTimer?.cancel();
    _connectionCheckTimer?.cancel();
    super.dispose();
  }
}
