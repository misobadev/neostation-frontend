import 'dart:convert';
import 'dart:async';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:neostation/models/notification_models.dart';
import 'dart:io';
import 'package:neostation/utils/app_config.dart';
import 'package:flutter/material.dart';
import 'package:neostation/widgets/plan_welcome_modal.dart';
import 'package:neostation/widgets/plan_farewell_modal.dart';
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:neostation/sync/providers/neo_sync_adapter.dart';
import 'package:provider/provider.dart';
import 'package:neostation/services/logger_service.dart';

/// Service responsible for real-time notifications via WebSockets.
///
/// Handles live updates for subscription plan changes, payment status, and
/// synchronization events. Includes automatic reconnection logic, health checks,
/// and UI integration for displaying system modals.
class NotificationService extends ChangeNotifier {
  static const String _tokenKey = 'auth_token';
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final _log = LoggerService.instance;

  WebSocketChannel? _channel;
  bool _isConnected = false;
  bool _isConnecting = false;
  String? _lastError;
  final List<NotificationMessage> _notifications = [];

  /// Global build context used for triggering overlay modals from background events.
  BuildContext? _context;

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
      notifyListeners();
    });
  }

  /// Sets the primary [BuildContext] for rendering system-wide notification modals.
  void setContext(BuildContext? context) {
    _context = context;
  }

  /// Triggers the appropriate welcome or farewell modal based on plan changes.
  void _showPlanUpdateModalImmediately(NotificationMessage notification) {
    if (_context == null || !_context!.mounted) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_context != null && _context!.mounted) {
        try {
          final authService = Provider.of<AuthService>(
            _context!,
            listen: false,
          );
          final currentPlan = authService.currentUser?.plan;

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
              PlanWelcomeModal.show(_context!, currentPlan);
            } else {
              final oldPlan = notification.data['old_plan'];
              if (oldPlan != null) {
                PlanFarewellModal.show(_context!, oldPlan, currentPlan);
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
    if (_context == null || !_context!.mounted) return;

    try {
      final authService = Provider.of<AuthService>(_context!, listen: false);
      final neoSyncProvider = Provider.of<NeoSyncProvider>(
        _context!,
        listen: false,
      );

      authService.getProfile().then((_) {
        try {
          final profileWidgetState = _context?.findAncestorStateOfType<State>();
          if (profileWidgetState != null) {
            _safeNotifyListeners();
          }
        } catch (e) {
          _log.e('Could not force profile widget refresh: $e');
        }
      });

      neoSyncProvider.loadFiles().then((_) {});
      neoSyncProvider.loadQuota().then((_) {});
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
    if (Platform.isMacOS) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_tokenKey);
    }
    return await _storage.read(key: _tokenKey);
  }

  /// Establishes the WebSocket connection with the notification server.
  ///
  /// Authenticates using the stored JWT and initiates health monitoring and
  /// missed notification retrieval.
  Future<void> connect() async {
    _shouldAutoReconnect = true;
    if (_isConnected || _isConnecting) {
      return;
    }

    // Notifications are NeoSync-specific; gate behind provider check.
    if (SyncManager.instance.active?.providerId != NeoSyncAdapter.kProviderId) {
      return;
    }

    _isConnecting = true;
    _lastError = null;
    _safeNotifyListeners();

    try {
      final token = await _getToken();
      if (token == null) {
        throw Exception('Not authenticated');
      }

      if (!_isUserAuthenticatedForNeoSync()) {
        _isConnecting = false;
        _lastError = 'NeoSync authentication required';
        _safeNotifyListeners();
        return;
      }

      final wsUrl = '${AppConfig.notifyBaseUrl}?token=$token';

      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));

      _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDisconnected,
      );

      await _channel!.ready.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw TimeoutException('WebSocket connection timeout');
        },
      );

      _isConnected = true;
      _isConnecting = false;
      _reconnectAttempts = 0;

      _startConnectionMonitoring();
      _requestMissedNotifications();

      _safeNotifyListeners();
    } catch (e) {
      _isConnecting = false;
      _lastError = 'Connection failed: $e';

      _log.w('WebSocket connection failed: $e');

      _channel?.sink.close();
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

    if (_channel != null) {
      _channel!.sink.close(status.goingAway);
      _channel = null;
    }

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
    _shouldAutoReconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
    _stopConnectionMonitoring();
    _channel?.sink.close(status.goingAway);
    _channel = null;
    _isConnected = false;
    _isConnecting = false;
    _safeNotifyListeners();
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
    if (_context == null) {
      return false;
    }

    try {
      final syncProvider = SyncManager.instance.active;
      if (syncProvider == null || !syncProvider.isAuthenticated) {
        return false;
      }

      final authService = Provider.of<AuthService>(_context!, listen: false);

      if (!authService.isLoggedIn) {
        return false;
      }

      final user = authService.currentUser;
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
    _shouldAutoReconnect = false;
    disconnect();
    _reconnectTimer?.cancel();
    _connectionCheckTimer?.cancel();
    super.dispose();
  }
}
