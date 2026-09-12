import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:neostation/models/billing_models.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/utils/app_config.dart';
import 'package:neostation/utils/log_redaction.dart';
import 'package:flutter/material.dart';

/// Service responsible for managing subscriptions, billing sessions, and available plans.
///
/// Interacts with the NeoStation billing backend to initiate checkout flows,
/// manage subscription cancellations, and retrieve pricing information.
class BillingService extends ChangeNotifier {
  /// Storage key for the authentication JWT token required for billing requests.
  static const String _tokenKey = 'auth_token';

  /// Primary storage for sensitive credentials.

  final _log = LoggerService.instance;

  /// Whether a billing-related network request is currently active.
  bool _isLoading = false;

  /// The last error message encountered during billing operations.
  String? _lastError;

  bool get isLoading => _isLoading;
  String? get lastError => _lastError;

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
    _isLoading = true;
    _lastError = null;
    _safeNotifyListeners();

    try {
      final headers = await _getHeaders();
      final baseUrl = AppConfig.billingBaseUrl;
      final uri = Uri.parse('$baseUrl/create-checkout-session');

      final body = {
        'user_id': userId,
        'plan_name': planName,
        'billing_period': billingPeriod,
        'email': email,
      };

      final response = await http.post(
        uri,
        headers: headers,
        body: jsonEncode(body),
      );

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
      return {'success': false, 'message': error};
    } finally {
      _isLoading = false;
      _safeNotifyListeners();
    }
  }

  /// Requests the immediate cancellation of the user's active subscription.
  Future<Map<String, dynamic>> cancelSubscription(String userId) async {
    _isLoading = true;
    _lastError = null;
    _safeNotifyListeners();

    try {
      final headers = await _getHeaders();
      final baseUrl = AppConfig.billingBaseUrl;
      final uri = Uri.parse('$baseUrl/cancel-subscription');

      final body = {'user_id': userId};

      final response = await http.post(
        uri,
        headers: headers,
        body: jsonEncode(body),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        return {'success': true};
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
      return {'success': false, 'message': error};
    } finally {
      _isLoading = false;
      _safeNotifyListeners();
    }
  }

  /// Fetches the list of subscription tiers and pricing currently offered by the service.
  Future<Map<String, dynamic>> getAvailablePlans() async {
    _isLoading = true;
    _lastError = null;
    _safeNotifyListeners();

    try {
      final headers = await _getHeaders();
      final baseUrl = AppConfig.billingBaseUrl;
      final uri = Uri.parse('$baseUrl/plans');

      final response = await http.get(uri, headers: headers);

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
      return {'success': false, 'message': error};
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
