import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:neostation/models/user.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/utils/app_config.dart';
import 'package:neostation/utils/log_redaction.dart';

/// Service responsible for managing user authentication and profile synchronization.
///
/// Handles registration, login, email verification, password recovery, and
/// session persistence. Where the token is kept is [CredentialStore]'s problem,
/// including the platforms whose secure storage cannot hold it.
class AuthService extends ChangeNotifier {
  /// Storage key for the authentication JWT token.
  static const String _tokenKey = 'auth_token';

  static final _log = LoggerService.instance;

  /// Whether a valid user session is currently active.
  bool _isLoggedIn = false;

  /// Metadata for the currently authenticated user.
  User? _currentUser;

  bool get isLoggedIn => _isLoggedIn;
  User? get currentUser => _currentUser;

  /// Initializes the service by attempting to restore a previous session from storage.
  ///
  /// If a token is found, it performs a profile fetch to validate its authenticity.
  /// Implements defensive logic to preserve tokens during network failures
  /// while purging them on explicit authentication errors (401/403).
  Future<void> initialize() async {
    try {
      final token = await CredentialStore.read(_tokenKey);
      if (token != null) {
        final profileResult = await getProfile();
        if (profileResult['success'] == true) {
          _isLoggedIn = true;
        } else if (profileResult['isNetworkError'] == true) {
          _isLoggedIn = false;
          _log.i(
            'AuthService: Network error during initialization. Token preserved.',
          );
        } else {
          final statusCode = profileResult['statusCode'];
          if (statusCode == 401 || statusCode == 403) {
            _log.w(
              'AuthService: Token invalid or expired ($statusCode). Clearing storage.',
            );
            await CredentialStore.delete(_tokenKey);
          } else {
            _log.i(
              'AuthService: Unexpected server error ($statusCode). Token preserved.',
            );
          }
          _isLoggedIn = false;
          _currentUser = null;
        }
      } else {
        _isLoggedIn = false;
        _currentUser = null;
      }
    } catch (e) {
      _isLoggedIn = false;
      _currentUser = null;
      _log.e('Error initializing auth service: $e');
    }
    notifyListeners();
  }

  /// Registers a new user account with the remote authentication server.
  ///
  /// Returns a status map indicating success or failure with a descriptive message.
  Future<Map<String, dynamic>> register(
    String username,
    String email,
    String password,
  ) async {
    try {
      final baseUrl = AppConfig.authBaseUrl;
      _log.i('Attempting registration to: $baseUrl/register');

      final response = await http.post(
        Uri.parse('$baseUrl/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username,
          'email': email,
          'password': password,
        }),
      );

      final data = jsonDecode(response.body);

      if (response.statusCode == 201) {
        return {
          'success': true,
          'message':
              'Registration successful. Please check your email to verify your account.',
        };
      } else {
        return {
          'success': false,
          'message': redactSecrets(data['error'] ?? 'Registration failed'),
        };
      }
    } catch (e) {
      return {'success': false, 'message': redactSecrets('Network error: $e')};
    }
  }

  /// Authenticates a user using their email and password.
  ///
  /// Upon successful authentication, it stores the JWT token securely,
  /// updates the internal [_currentUser] state, and notifies listeners.
  Future<Map<String, dynamic>> login(String email, String password) async {
    try {
      final baseUrl = AppConfig.authBaseUrl;
      _log.i('Attempting login to: $baseUrl/login');

      final response = await http.post(
        Uri.parse('$baseUrl/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'password': password}),
      );

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        final token = data['token'];
        final userData = data['user'];

        final storage = await CredentialStore.write(_tokenKey, token);
        final tokenPersisted = storage != CredentialWriteOutcome.sessionOnly;
        if (!tokenPersisted) {
          _log.w(
            'Login succeeded but the token could not be persisted; the '
            'session ends when the app closes',
          );
        }

        _currentUser = User.fromJson(userData);
        _isLoggedIn = true;
        notifyListeners();

        final user = User.fromJson(userData);
        if (!user.emailVerified) {
          return {
            'success': true,
            'message': 'Login successful, but email not verified',
            'emailVerified': false,
            'user': user,
            'tokenPersisted': tokenPersisted,
          };
        }

        return {
          'success': true,
          'message': 'Login successful',
          'emailVerified': true,
          'user': user,
          'tokenPersisted': tokenPersisted,
        };
      } else {
        String errorMessage = redactSecrets(data['error'] ?? 'Login failed');
        return {
          'success': false,
          'message': errorMessage,
          'emailNotVerified': errorMessage.toLowerCase().contains(
            'email not verified',
          ),
        };
      }
    } catch (e) {
      return {'success': false, 'message': redactSecrets('Network error: $e')};
    }
  }

  /// Verifies a user's email using a verification [token] sent via email.
  Future<Map<String, dynamic>> verifyEmail(String token) async {
    try {
      final response = await http.post(
        Uri.parse('${AppConfig.authBaseUrl}/verify-email'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'token': token}),
      );

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        return {'success': true, 'message': 'Email verified successfully'};
      } else {
        String errorMessage = 'Verification failed';
        if (data['error'] != null) {
          errorMessage = redactSecrets(data['error']);
        } else if (data['message'] != null) {
          errorMessage = redactSecrets(data['message']);
        }

        return {'success': false, 'message': errorMessage};
      }
    } catch (e) {
      return {'success': false, 'message': redactSecrets('Network error: $e')};
    }
  }

  /// Checks the current verification status of an email address.
  Future<Map<String, dynamic>> checkEmailVerificationStatus(
    String email,
  ) async {
    try {
      final response = await http.post(
        Uri.parse('${AppConfig.authBaseUrl}/check-email-status'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email}),
      );

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        return {
          'success': true,
          'email_verified': data['email_verified'] ?? false,
          'username': data['username'],
        };
      } else {
        return {
          'success': false,
          'message': redactSecrets(data['error'] ?? 'Failed to check status'),
        };
      }
    } catch (e) {
      return {'success': false, 'message': redactSecrets('Network error: $e')};
    }
  }

  /// Triggers a resend of the account verification email to the specified address.
  Future<Map<String, dynamic>> resendVerificationEmail(String email) async {
    try {
      final response = await http.post(
        Uri.parse('${AppConfig.authBaseUrl}/resend-verification'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email}),
      );

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        return {'success': true, 'message': 'Verification email sent'};
      } else {
        return {
          'success': false,
          'message': redactSecrets(
            data['error'] ?? 'Failed to send verification email',
          ),
        };
      }
    } catch (e) {
      return {'success': false, 'message': redactSecrets('Network error: $e')};
    }
  }

  /// Fetches the detailed user profile for the current authenticated session.
  ///
  /// Automatically updates the internal [_currentUser] state on success.
  Future<Map<String, dynamic>> getProfile() async {
    try {
      final token = await CredentialStore.read(_tokenKey);
      if (token == null) {
        return {'success': false, 'message': 'Not authenticated'};
      }

      final response = await http.get(
        Uri.parse('${AppConfig.authBaseUrl}/auth/me'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        _currentUser = User.fromJson(data);
        notifyListeners();
        return {'success': true, 'user': _currentUser};
      } else {
        return {
          'success': false,
          'message': redactSecrets(data['error'] ?? 'Failed to get profile'),
          'statusCode': response.statusCode,
        };
      }
    } catch (e) {
      return {
        'success': false,
        'message': redactSecrets('Network error: $e'),
        'isNetworkError': true,
      };
    }
  }

  /// Initiates a password recovery request for the specified email address.
  Future<Map<String, dynamic>> forgotPassword(String email) async {
    try {
      final response = await http.post(
        Uri.parse('${AppConfig.authBaseUrl}/forgot-password'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email}),
      );

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        return {
          'success': true,
          'message': data['message'] ?? 'Password reset email sent',
        };
      } else {
        return {
          'success': false,
          'message': redactSecrets(
            data['error'] ??
                data['message'] ??
                'Failed to send password reset email',
          ),
        };
      }
    } catch (e) {
      return {'success': false, 'message': redactSecrets('Network error: $e')};
    }
  }

  /// Resets a user's password using a recovery [token] and a [newPassword].
  Future<Map<String, dynamic>> resetPassword(
    String token,
    String newPassword,
  ) async {
    try {
      final response = await http.post(
        Uri.parse('${AppConfig.authBaseUrl}/reset-password'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'token': token, 'new_password': newPassword}),
      );

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        return {
          'success': true,
          'message': data['message'] ?? 'Password reset successfully',
        };
      } else {
        return {
          'success': false,
          'message': redactSecrets(
            data['error'] ?? data['message'] ?? 'Failed to reset password',
          ),
        };
      }
    } catch (e) {
      return {'success': false, 'message': redactSecrets('Network error: $e')};
    }
  }

  /// Terminates the current user session and purges the stored authentication token.
  Future<void> logout() async {
    await CredentialStore.delete(_tokenKey);
    _isLoggedIn = false;
    _currentUser = null;
    notifyListeners();
  }
}
