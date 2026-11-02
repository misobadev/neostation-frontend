import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:neostation/models/billing_models.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/neosync/neosync_http.dart';
import 'package:neostation/utils/app_config.dart';
import 'package:neostation/utils/log_redaction.dart';
import 'package:flutter/material.dart';

/// Service responsible for managing subscriptions, billing sessions, and available plans.
///
/// Interacts with the NeoStation billing backend to initiate checkout flows,
/// manage subscription cancellations, and retrieve pricing information.
class BillingService extends ChangeNotifier {
  BillingService({
    http.Client? client,
    this.requestTimeout = defaultRequestTimeout,
  }) : _client = client ?? neoSyncHttpClient(requestTimeout),
       _ownsClient = client == null;

  /// Storage key for the authentication JWT token required for billing requests.
  static const String _tokenKey = 'auth_token';

  /// How long a billing request (plans, checkout, cancellation) may take.
  /// Without a limit, a server that takes the connection and then says
  /// nothing would keep the plan list loading for as long as the socket lived.
  static const Duration defaultRequestTimeout = Duration(seconds: 15);

  /// The limit for each billing request (and for connecting, on the default
  /// client); see [defaultRequestTimeout].
  final Duration requestTimeout;
  final http.Client _client;
  final bool _ownsClient;

  /// Primary storage for sensitive credentials.

  final _log = LoggerService.instance;

  /// Whether a billing-related network request is currently active.
  bool _isLoading = false;

  /// The last error message encountered during billing operations.
  String? _lastError;

  /// Whether a checkout or a cancellation is out. One flag for both: they
  /// change the same subscription, so a second change sent before the first
  /// is answered (a repeated A press, or an upgrade racing a cancellation)
  /// would be applied on top of a state neither request saw. Not
  /// [_isLoading], which the plan list shares: loading the plans is a read,
  /// and neither holds up nor is held up by a change.
  bool _changeInFlight = false;

  /// Gateway answers (bad gateway, unavailable, gateway timeout): a proxy in
  /// front of the billing server answered for it, so a change may still have
  /// been applied behind it.
  static const Set<int> _gatewayStatuses = {502, 503, 504};

  bool get isLoading => _isLoading;
  String? get lastError => _lastError;

  /// Whether a checkout or a cancellation is still out, so a view opened
  /// meanwhile shows it running rather than sending another.
  bool get isChangeInFlight => _changeInFlight;

  @override
  void dispose() {
    if (_ownsClient) _client.close();
    super.dispose();
  }

  /// Internal helper to trigger UI updates safely, avoiding issues during build phases.
  void _safeNotifyListeners() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      notifyListeners();
    });
  }

  /// Retrieves the current authentication token from secure storage.
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

  /// Constructs the standard HTTP headers for authenticated billing API requests.
  Future<Map<String, String>> _getHeaders() async {
    final token = await _getToken();
    return {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
  }

  /// Initiates a new Stripe/payment checkout session for a specific subscription plan.
  ///
  /// The [planName] and [billingPeriod] (e.g., 'monthly', 'yearly') determine
  /// the transaction parameters. Returns a session URL or upgrade confirmation.
  Future<Map<String, dynamic>> createCheckoutSession({
    required String userId,
    required String planName,
    required String billingPeriod,
    required String email,
  }) async {
    // Set before the first await, so a second call made straight after this
    // one already sees it.
    if (_changeInFlight) return {'success': false, 'busy': true};
    _changeInFlight = true;
    _isLoading = true;
    _lastError = null;

    try {
      _safeNotifyListeners();
      final headers = await _getHeaders();
      final baseUrl = AppConfig.billingBaseUrl;
      final uri = Uri.parse('$baseUrl/create-checkout-session');

      final body = {
        'user_id': userId,
        'plan_name': planName,
        'billing_period': billingPeriod,
        'email': email,
      };

      final response = await sendWithTimeout(
        _client,
        'POST',
        uri,
        headers: headers,
        body: jsonEncode(body),
        timeout: requestTimeout,
      );
      if (_gatewayStatuses.contains(response.statusCode)) {
        _log.e('Checkout unconfirmed: HTTP ${response.statusCode}');
        return _unconfirmed('HTTP ${response.statusCode}');
      }

      final data = jsonDecode(response.body);

      if (response.statusCode == 200 || response.statusCode == 201) {
        if (data['type'] == 'upgrade') {
          return {'success': true, 'upgrade': true, 'message': data['message']};
        } else {
          final session = BillingSession.fromJson(data);
          return {'success': true, 'session': session};
        }
      } else {
        final error = redactSecrets(
          data['error'] ?? 'Failed to create checkout session',
        );
        return {'success': false, 'message': error};
      }
    } catch (e) {
      final error = redactSecrets('Network error: $e');
      _log.e('Checkout creation error: $error');
      _lastError = error;
      return _unconfirmed(error);
    } finally {
      _changeInFlight = false;
      _isLoading = false;
      _safeNotifyListeners();
    }
  }

  /// Requests the immediate cancellation of the user's active subscription.
  Future<Map<String, dynamic>> cancelSubscription(String userId) async {
    // See createCheckoutSession.
    if (_changeInFlight) return {'success': false, 'busy': true};
    _changeInFlight = true;
    _isLoading = true;
    _lastError = null;

    try {
      _safeNotifyListeners();
      final headers = await _getHeaders();
      final baseUrl = AppConfig.billingBaseUrl;
      final uri = Uri.parse('$baseUrl/cancel-subscription');

      final body = {'user_id': userId};

      final response = await sendWithTimeout(
        _client,
        'POST',
        uri,
        headers: headers,
        body: jsonEncode(body),
        timeout: requestTimeout,
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        return {'success': true};
      } else if (_gatewayStatuses.contains(response.statusCode)) {
        _log.e('Cancellation unconfirmed: HTTP ${response.statusCode}');
        return _unconfirmed('HTTP ${response.statusCode}');
      } else {
        final data = jsonDecode(response.body);
        final error = redactSecrets(
          data['error'] ?? 'Failed to cancel subscription',
        );
        _log.e('Cancellation failed: $error');
        return {'success': false, 'message': error};
      }
    } catch (e) {
      final error = redactSecrets('Network error: $e');
      _log.e('Cancellation error: $error');
      _lastError = error;
      return _unconfirmed(error);
    } finally {
      _changeInFlight = false;
      _isLoading = false;
      _safeNotifyListeners();
    }
  }

  /// The answer to a checkout or cancellation that got no readable reply: it
  /// timed out, the connection failed or dropped, the body wasn't JSON, or a
  /// gateway answered for the server. The server may still have applied the
  /// change (`outcomeUnknown`); `isNetworkError` stays for callers that only
  /// tell a failure to reach NeoSync from a refusal.
  Map<String, dynamic> _unconfirmed(String error) => {
    'success': false,
    'message': error,
    'isNetworkError': true,
    'outcomeUnknown': true,
  };

  /// Fetches the list of subscription tiers and pricing currently offered by the service.
  Future<Map<String, dynamic>> getAvailablePlans() async {
    _isLoading = true;
    _lastError = null;
    _safeNotifyListeners();

    try {
      final headers = await _getHeaders();
      final baseUrl = AppConfig.billingBaseUrl;
      final uri = Uri.parse('$baseUrl/plans');

      final response = await sendWithTimeout(
        _client,
        'GET',
        uri,
        headers: headers,
        timeout: requestTimeout,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final plans =
            (data['plans'] as List?)
                ?.map((plan) => PlanInfo.fromJson(plan))
                .toList() ??
            [];

        return {'success': true, 'plans': plans};
      } else {
        final data = jsonDecode(response.body);
        final error = redactSecrets(data['error'] ?? 'Failed to fetch plans');
        _log.e('Plans fetch failed: $error');
        return {'success': false, 'message': error};
      }
    } catch (e) {
      final error = redactSecrets('Network error: $e');
      _log.e('Plans fetch error: $error');
      _lastError = error;
      return {'success': false, 'message': error, 'isNetworkError': true};
    } finally {
      _isLoading = false;
      _safeNotifyListeners();
    }
  }

  /// Resets the internal error state.
  void clearError() {
    _lastError = null;
    _safeNotifyListeners();
  }
}
