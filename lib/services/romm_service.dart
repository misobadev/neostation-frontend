import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show immutable, visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' as path;

import '../models/romm_asset.dart';
import '../models/romm_collection.dart';
import '../models/romm_platform.dart';
import '../models/romm_rom_page.dart';
import '../models/romm_play_session.dart';
import '../models/romm_rom.dart';
import 'logger_service.dart';

/// Why connecting to a RomM server failed, so the UI can say it in the app
/// language. Everything else is [RommFailure.other].
enum RommFailure {
  /// The address answered, but not over TLS (most often an http-only server
  /// reached as https://, which is what an address without a scheme becomes).
  tls,

  /// The server couldn't be reached at all; [RommException.detail] holds the
  /// system's reason.
  unreachable,

  /// The server didn't answer in time.
  timeout,

  /// The username or password was rejected.
  invalidCredentials,

  /// The API key was rejected.
  invalidApiKey,

  /// The server answered with a status other than success or rejection;
  /// [RommException.statusCode] holds it.
  unexpectedStatus,

  /// The server answered, but not like RomM (no token in its answer, or not
  /// the JSON RomM sends).
  notRomm,

  /// A server already confirmed as RomM answered a request with an error
  /// status; [RommException.statusCode] holds it.
  serverError,

  /// Any other failure: shown as the generic "connection failed".
  other,
}

/// The start of a response body, whitespace collapsed, for the log: enough to
/// tell a router's login page or another app from RomM.
String _bodyExcerpt(String body) {
  final text = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  return text.length <= 160 ? text : '${text.substring(0, 160)}…';
}

/// Raised when a RomM API call fails. [message] is English, for the log; the
/// UI says [kind] in the app language instead.
class RommException implements Exception {
  final String message;
  final int? statusCode;
  final RommFailure kind;

  /// A detail worth showing with [kind], e.g. the system's reason a server
  /// couldn't be reached.
  final String? detail;

  /// The start of what the server answered (content type and a short,
  /// whitespace-collapsed excerpt), for the log only: it tells a web server's
  /// own error page from RomM's. Never shown to the user.
  final String? serverResponse;

  RommException(
    this.message, {
    this.statusCode,
    this.serverResponse,
    this.kind = RommFailure.other,
    this.detail,
  });

  @override
  String toString() => 'RommException($statusCode): $message';
}

/// Raised when a download is aborted because the caller's `shouldCancel`
/// callback returned true. A distinct type (rather than matching on the
/// message string) lets callers reliably tell a user-cancelled download apart
/// from a genuine failure, even if the message is later reworded/localized.
class RommCancelledException extends RommException {
  RommCancelledException([super.message = 'Download cancelled']);
}

/// Why [RommService.fetchImage] produced no bytes.
///
/// The distinction exists because a caller that caches a negative answer must
/// only cache a *definite* one. Collapsing both into a bare null is what let a
/// single timeout hide a cover until the connection was reconfigured.
enum RommImageMiss {
  /// The server answered, and there is nothing behind this URL: a `404`/`410`,
  /// or a `200` whose body is not an image (RomM falls through to its SPA
  /// shell for a resource path it no longer has a file for). Asking again
  /// cannot change the answer until the server itself changes.
  absent,

  /// No usable answer arrived: a timeout, a socket or TLS failure, a `5xx`, a
  /// `401`/`403`. Says nothing about whether the image exists, so it must stay
  /// retryable.
  unreachable,
}

/// The result of [RommService.fetchImage]: the bytes, or why there are none.
@immutable
class RommImageFetch {
  /// A successful fetch.
  const RommImageFetch.found(Uint8List this.bytes) : miss = null;

  /// A fetch that produced nothing, and why.
  const RommImageFetch.missing(RommImageMiss this.miss) : bytes = null;

  /// The image bytes, or null when [miss] is set.
  final Uint8List? bytes;

  /// Why there are no [bytes], or null on success.
  final RommImageMiss? miss;

  /// Whether the server gave a definite negative answer — the only case a
  /// caller may treat as permanent.
  bool get isAbsent => miss == RommImageMiss.absent;
}

/// HTTP client for a remote RomM server (library browse + ROM download).
///
/// Holds the server base URL and credentials for one connection. Two
/// authentication modes are supported, chosen by what [configure] is given:
///
/// * **OAuth2 password grant** (`POST /api/token`) — username + password. JWTs
///   are cached and transparently refreshed on expiry / 401.
/// * **Client API Token** — a `rmm_…` key the user creates in RomM. It is sent
///   as the bearer token directly, never expires, and has no refresh flow, so
///   the whole token lifecycle collapses to "use the key".
///
/// Modeled on the IOClient + bad-certificate setup used by [ScreenScraperService]
/// so self-signed homelab certificates work.
class RommService {
  /// The limits default to the production ones; tests pass short ones.
  RommService({
    this.uploadStallLimit = uploadStallTimeout,
    this.uploadResponseLimit = uploadResponseTimeout,
    this.assetRequestLimit = downloadRequestTimeout,
    this.assetStallLimit = downloadStallTimeout,
  });

  static final _log = LoggerService.instance;

  /// Scopes requested in the password grant. RomM grants the intersection of
  /// these and the user's allowed scopes; covers library browse + download plus
  /// save/state sync (`assets.write`).
  static const String _readScopes =
      'me.read roms.read platforms.read assets.read assets.write collections.read firmware.read';

  /// Extra scopes needed for playtime sync (`/api/play-sessions`). Requested on
  /// top of [_readScopes], but *optionally*: RomM's token endpoint rejects the
  /// whole grant with a 403 if any requested scope is outside the user's
  /// allowance, and these two don't exist at all on servers older than the
  /// play-session feature. [authenticate] therefore falls back to the base
  /// scope set rather than turning "no playtime sync" into "cannot log in".
  static const String _playtimeScopes = 'roms.user.read roms.user.write';

  /// Maximum sessions RomM accepts in one `/api/play-sessions` POST.
  static const int maxPlaySessionBatch = 100;

  /// How long connecting to the server may take, so an address that swallows
  /// the handshake fails in good time rather than at the system's own limit.
  /// Longer than the 30 s limits on the sign-in requests, so signing in to an
  /// address that never answers still fails as a timeout first, as it did
  /// before; it is the uploads, which have no overall limit, it bounds.
  @visibleForTesting
  static const connectTimeout = Duration(seconds: 45);

  /// Builds the [HttpClient] behind [_sharedHttpClient]: tolerates self-signed
  /// certificates (homelab servers) and gives up connecting after
  /// [connectTimeout].
  @visibleForTesting
  static HttpClient newHttpClient() => HttpClient()
    ..connectionTimeout = connectTimeout
    ..badCertificateCallback = ((X509Certificate cert, String host, int port) =>
        true);

  /// Shared client that tolerates self-signed certificates (homelab servers).
  static final http.Client _sharedHttpClient = IOClient(newHttpClient());

  /// Test seam: when set, every request goes through this client instead of
  /// [_sharedHttpClient]. Process-wide, like the client it replaces.
  static http.Client? _httpClientOverride;

  /// Opens the part file a ROM download writes to.
  static Future<RandomAccessFile> Function(File file) _openPartFile =
      _openForWrite;

  static Future<RandomAccessFile> _openForWrite(File file) =>
      file.open(mode: FileMode.write);

  /// Replaces how a ROM download opens its part file, or restores it with
  /// null, so a test can hold or fail its writes.
  @visibleForTesting
  static void debugUsePartFileOpener(
    Future<RandomAccessFile> Function(File file)? open,
  ) {
    _openPartFile = open ?? _openForWrite;
  }

  /// Routes all RomM HTTP through [client] (a `MockClient`, typically); pass
  /// null to restore the shared client.
  @visibleForTesting
  static void debugUseHttpClient(http.Client? client) {
    _httpClientOverride = client;
  }

  static http.Client get _httpClient =>
      _httpClientOverride ?? _sharedHttpClient;

  String _baseUrl = '';

  String _username = '';
  String _password = '';
  String _apiKey = '';
  String? _accessToken;
  String? _refreshToken;
  int? _tokenExpiresMs;

  /// Whether the server granted the playtime scopes at the last authentication.
  /// Starts optimistic: a token restored from disk may predate the scopes, and
  /// the shared 403-retry re-authenticates (picking them up) before giving up.
  bool _playtimeScopeGranted = true;

  /// Cleared for the rest of this connection once the server proves it has no
  /// play-session API (404) or won't grant access to it (403 after a re-auth),
  /// so a RomM older than the feature isn't probed on every sync.
  bool _playSessionsSupported = true;

  /// Whether playtime sync can be attempted against this server.
  bool get playtimeSyncAvailable =>
      _playtimeScopeGranted && _playSessionsSupported;

  /// Advanced by every [configure]. A request reads the server and credentials
  /// only when it is sent, so one begun under an earlier connection must not
  /// be sent, retried, or store a token under this one.
  int _session = 0;

  /// Identifies the current connection. Asset and ROM IDs are only meaningful
  /// on the connection they came from: another server or account can reuse
  /// them for unrelated files.
  int get session => _session;

  /// Throws when [configure] has run since [session] was read.
  void _checkSession(int session) {
    if (session != _session) throw RommException('Connection changed');
  }

  String get baseUrl => _baseUrl;

  /// The account this connection belongs to. With the password grant it is
  /// whatever the user typed; with an API key it is filled in from
  /// `/api/users/me` at [authenticate] time, since the key alone doesn't name
  /// its owner.
  String get username => _username;

  /// Whether this connection authenticates with a Client API Token. Callers
  /// that persist the connection use it to decide which secret to store.
  bool get usesApiKey => _apiKey.isNotEmpty;

  /// The API key in use, or an empty string on a password-grant connection.
  String get apiKey => _apiKey;

  /// The cached OAuth2 access token — always null in API-key mode, where there
  /// is nothing to cache and the key itself is the bearer credential.
  String? get accessToken => _accessToken;
  String? get refreshToken => _refreshToken;
  int? get tokenExpiresMs => _tokenExpiresMs;

  /// Configures the connection. [serverUrl] may include or omit a scheme and
  /// trailing slash; it is normalized to `scheme://host[:port]` with no
  /// trailing slash.
  ///
  /// Pass either [username]/[password] or a non-empty [apiKey]; a key wins if
  /// both are somehow given, and puts the service in API-key mode where the
  /// [accessToken]/[refreshToken]/[tokenExpiresMs] restore arguments are
  /// meaningless and ignored.
  void configure({
    required String serverUrl,
    String username = '',
    String password = '',
    String apiKey = '',
    String? accessToken,
    String? refreshToken,
    int? tokenExpiresMs,
  }) {
    _session++;
    // A different server (or a reconnect) knows nothing about the last one's
    // missing covers.
    _deadCovers.clear();
    final raw = serverUrl.trim();
    _baseUrl = _normalizeBaseUrl(raw);
    _apiKey = apiKey.trim();
    _username = username;
    _password = _apiKey.isEmpty ? password : '';
    _accessToken = _apiKey.isEmpty ? accessToken : null;
    _refreshToken = _apiKey.isEmpty ? refreshToken : null;
    _tokenExpiresMs = _apiKey.isEmpty ? tokenExpiresMs : null;
    // Playtime support is a property of the server we're pointed at, so a
    // reconfigure (different server, or the same one after an edit) re-probes
    // instead of inheriting the previous server's verdict.
    _playtimeScopeGranted = true;
    _playSessionsSupported = true;
  }

  static String _normalizeBaseUrl(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return url;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  Uri _uri(String pathAndQuery) => Uri.parse('$_baseUrl$pathAndQuery');

  bool get _tokenLikelyValid {
    // An API key never expires and has no refresh flow, so it is always the
    // credential to send: there is nothing for _ensureToken to do.
    if (usesApiKey) return true;
    if (_accessToken == null || _accessToken!.isEmpty) return false;
    final exp = _tokenExpiresMs;
    if (exp == null) return true; // assume valid until a 401 proves otherwise
    // Refresh 30s early to avoid edge-of-expiry races.
    return DateTime.now().millisecondsSinceEpoch < exp - 30000;
  }

  // ── Authentication ─────────────────────────────────────────────────────────

  /// POSTs to `/api/token`.
  ///
  /// Always over the scheme the user configured: a TLS failure is reported to
  /// the user rather than retried over plain HTTP, since this request carries
  /// the password or refresh token. A server that really is plain HTTP is
  /// entered as `http://`.
  Future<http.Response> _postTokenRequest(Map<String, String> body) {
    const headers = {'Content-Type': 'application/x-www-form-urlencoded'};
    return _httpClient
        .post(_uri('/api/token'), headers: headers, body: body)
        .timeout(const Duration(seconds: 30));
  }

  /// Establishes (or confirms) a usable credential, dispatching on the mode the
  /// service was configured in. Throws [RommException] on failure; its
  /// [RommException.kind] says why.
  Future<void> authenticate() async {
    if (_baseUrl.isEmpty) {
      throw RommException('Server URL is empty');
    }
    if (usesApiKey) return _verifyApiKey();
    return _authenticateWithPassword();
  }

  /// Confirms an API key by fetching its owner, which doubles as the source of
  /// the username shown in the UI (the key itself doesn't name its account).
  ///
  /// Nothing is cached: the key *is* the credential, so this is a validity
  /// check rather than a token exchange, and only ever runs on connect.
  Future<void> _verifyApiKey() async {
    final session = _session;
    http.Response resp;
    try {
      resp = await _httpClient
          .get(_uri('/api/users/me'), headers: _authHeaders)
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw RommException('Connection timed out', kind: RommFailure.timeout);
    } on HandshakeException {
      throw RommException(
        'TLS handshake failed — try an http:// URL if the server is not HTTPS',
        kind: RommFailure.tls,
      );
    } on SocketException catch (e) {
      throw RommException(
        'Cannot reach server: ${e.message}',
        kind: RommFailure.unreachable,
        detail: e.message,
      );
    } catch (e) {
      throw RommException('Connection failed: $e');
    }
    _checkSession(session);

    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw RommException(
        'Invalid API key',
        statusCode: resp.statusCode,
        kind: RommFailure.invalidApiKey,
      );
    }
    if (resp.statusCode != 200) {
      throw RommException(
        'Authentication failed (${resp.statusCode})',
        statusCode: resp.statusCode,
        serverResponse: _bodyExcerpt(resp.body),
        kind: RommFailure.unexpectedStatus,
      );
    }

    // Anything can answer 200 at this path (a router's login page, a web
    // app's catch-all), so an answer that isn't JSON isn't RomM. A JSON answer
    // without the expected shape only costs us the display name.
    final Object? decoded;
    try {
      decoded = jsonDecode(resp.body);
    } catch (_) {
      throw RommException(
        'Server did not answer like RomM',
        serverResponse: _bodyExcerpt(resp.body),
        kind: RommFailure.notRomm,
      );
    }
    if (decoded is Map<String, dynamic>) {
      final name = decoded['username']?.toString();
      if (name != null && name.isNotEmpty) _username = name;
    }
  }

  /// Performs the OAuth2 password grant and stores the resulting tokens.
  Future<void> _authenticateWithPassword() async {
    Map<String, String> bodyFor(String scope) => {
      'grant_type': 'password',
      'username': _username,
      'password': _password,
      // RomM issues an empty-scope token (403 on every read endpoint) unless
      // the requested scopes are passed explicitly.
      'scope': scope,
    };

    final session = _session;
    http.Response resp;
    bool? playtimeGranted;
    try {
      resp = await _postTokenRequest(bodyFor('$_readScopes $_playtimeScopes'));
      if (resp.statusCode == 403 && session == _session) {
        // Either the account lacks the playtime scopes or the server predates
        // them — indistinguishable here, and both mean the same thing: keep the
        // connection, drop playtime sync. Bad credentials fail the retry too,
        // so the error path below is unchanged for them.
        final base = await _postTokenRequest(bodyFor(_readScopes));
        if (base.statusCode == 200) playtimeGranted = false;
        resp = base.statusCode == 200 ? base : resp;
      } else if (resp.statusCode == 200) {
        playtimeGranted = true;
      }
    } on TimeoutException {
      throw RommException('Connection timed out', kind: RommFailure.timeout);
    } on HandshakeException {
      throw RommException(
        'TLS handshake failed — try an http:// URL if the server is not HTTPS',
        kind: RommFailure.tls,
      );
    } on SocketException catch (e) {
      throw RommException(
        'Cannot reach server: ${e.message}',
        kind: RommFailure.unreachable,
        detail: e.message,
      );
    } catch (e) {
      throw RommException('Connection failed: $e');
    }
    _checkSession(session);

    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw RommException(
        'Invalid username or password',
        statusCode: resp.statusCode,
        kind: RommFailure.invalidCredentials,
      );
    }
    if (resp.statusCode != 200) {
      throw RommException(
        'Authentication failed (${resp.statusCode})',
        statusCode: resp.statusCode,
        serverResponse: _bodyExcerpt(resp.body),
        kind: RommFailure.unexpectedStatus,
      );
    }

    if (playtimeGranted != null) _playtimeScopeGranted = playtimeGranted;
    if (playtimeGranted == false) {
      _log.w('RomM denied $_playtimeScopes — playtime sync disabled');
    }
    _applyTokenResponse(resp.body);
  }

  Future<void> _refreshAccessToken() async {
    // An API key can't be refreshed or re-minted; if the server rejected it,
    // asking again with the same key would only repeat the rejection.
    if (usesApiKey) return;
    final refresh = _refreshToken;
    if (refresh == null || refresh.isEmpty) {
      // No refresh token: fall back to a full re-authentication.
      await authenticate();
      return;
    }
    final session = _session;
    try {
      final resp = await _postTokenRequest({
        'grant_type': 'refresh_token',
        'refresh_token': refresh,
      });
      if (resp.statusCode == 200 && session == _session) {
        _applyTokenResponse(resp.body);
        return;
      }
    } catch (e) {
      _log.w('RomM token refresh failed, re-authenticating: $e');
    }
    _checkSession(session);
    // Refresh failed for any reason: re-authenticate from credentials.
    await authenticate();
  }

  void _applyTokenResponse(String responseBody) {
    // A server that isn't RomM (a router's login page, another app on the
    // port) can answer 200 with something else entirely.
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(responseBody) as Map<String, dynamic>;
    } catch (_) {
      throw RommException(
        'Server did not answer with a token',
        serverResponse: _bodyExcerpt(responseBody),
        kind: RommFailure.notRomm,
      );
    }
    final access = json['access_token']?.toString();
    if (access == null || access.isEmpty) {
      throw RommException(
        'Server did not return an access token',
        kind: RommFailure.notRomm,
      );
    }
    _accessToken = access;
    final refresh = json['refresh_token']?.toString();
    if (refresh != null && refresh.isNotEmpty) {
      _refreshToken = refresh;
    }
    // `expires` is the access-token lifetime in seconds.
    final expiresSeconds = (json['expires'] as num?)?.toInt();
    _tokenExpiresMs = expiresSeconds != null
        ? DateTime.now().millisecondsSinceEpoch + expiresSeconds * 1000
        : null;
  }

  /// Ensures a usable access token, authenticating or refreshing as needed.
  Future<void> _ensureToken() async {
    if (_tokenLikelyValid) return;
    if (_accessToken != null && _refreshToken != null) {
      await _refreshAccessToken();
    } else {
      await authenticate();
    }
  }

  /// The credential to send. RomM accepts a Client API Token in exactly the
  /// same `Bearer` header as an OAuth2 access token, so every call site below
  /// is mode-agnostic.
  Map<String, String> get _authHeaders => {
    'Authorization': 'Bearer ${usesApiKey ? _apiKey : _accessToken}',
  };

  /// Whether a credential exists at all (used to decide if a request is worth
  /// attaching auth to).
  bool get _hasCredential =>
      usesApiKey || (_accessToken != null && _accessToken!.isNotEmpty);

  /// Authenticates and performs a lightweight call to confirm the connection
  /// and credentials are valid (used by [RommProvider.connect]).
  Future<void> verifyConnection() async {
    await authenticate();
    // In API-key mode authenticate() *is* the authorized `/api/users/me` call,
    // so repeating it here would only double the round trips.
    if (usesApiKey) return;
    // A successful, authorized call confirms the token works end-to-end. Hit
    // the lightweight `/api/users/me` rather than downloading the full platform
    // list — same auth guarantee, a fraction of the payload. authenticate()
    // surfaces bad credentials as 401/403. The token has just proven this is
    // RomM, so an error status from this call is the server's
    // ([RommFailure.serverError], as [_authedGetUri] tags it), not a wrong
    // address.
    await _authedGet('/api/users/me');
  }

  /// Validates a restored session, allowing cached tokens to refresh normally.
  Future<void> verifyStoredConnection() async {
    if (usesApiKey) return _verifyApiKey();
    await _authedGet('/api/users/me');
  }

  // ── Read endpoints ───────────────────────────────────────────────────────

  /// Sends an authenticated request via [send] and retries it once on an auth
  /// failure: `401` → refresh the access token, `403` → full re-authenticate
  /// (covers a cached token minted before the current scope set). [send] must
  /// build a *fresh* request each call so the retry picks up the new token.
  ///
  /// In API-key mode there is no retry: the key is fixed, its scopes were set
  /// when the user created it, and nothing about a second identical request
  /// would come out differently — so a 401/403 is passed straight to the caller.
  ///
  /// Works for both [http.Response] and [http.StreamedResponse] via [statusOf];
  /// this is the single retry policy shared by every authenticated call site
  /// (plain GETs, asset GETs, uploads and ROM downloads).
  ///
  /// Nothing is sent once [configure] has run since the call began, so a
  /// request waiting on authentication can't reach a different server, or
  /// carry its credentials to the original one.
  Future<T> _sendWithAuthRetry<T>(
    Future<T> Function() send, {
    required int Function(T resp) statusOf,
  }) async {
    // Both attempts map a timeout or an unreachable server the same way, so a
    // caller never sees a raw exception just because a token was refreshed.
    Future<T> attempt() async {
      try {
        return await send();
      } on TimeoutException {
        throw RommException('Request timed out', kind: RommFailure.timeout);
      } on HandshakeException {
        throw RommException('TLS handshake failed', kind: RommFailure.tls);
      } on SocketException catch (e) {
        // Also package:http's socket failures, which implement SocketException.
        throw RommException(
          'Cannot reach server: ${e.message}',
          kind: RommFailure.unreachable,
          detail: e.message,
        );
      } on http.ClientException catch (e) {
        throw RommException(
          'Cannot reach server: ${e.message}',
          kind: RommFailure.unreachable,
          detail: e.message,
        );
      }
    }

    final session = _session;
    await _ensureToken();
    _checkSession(session);
    final resp = await attempt();
    final status = statusOf(resp);
    if (status != 401 && status != 403) return resp;
    _checkSession(session);
    if (usesApiKey) return resp;
    await (status == 401 ? _refreshAccessToken() : authenticate());
    _checkSession(session);
    return attempt();
  }

  /// Issues an authenticated GET for a server-relative path+query, applying the
  /// shared [_sendWithAuthRetry] policy and throwing on any non-200.
  Future<http.Response> _authedGet(String pathAndQuery) =>
      _authedGetUri(_uri(pathAndQuery));

  /// Like [_authedGet] but for a fully-built [uri] (used where query parameters
  /// are assembled via [Uri] or the asset path needs bespoke encoding).
  Future<http.Response> _authedGetUri(
    Uri uri, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final resp = await _sendWithAuthRetry<http.Response>(
      () => _httpClient.get(uri, headers: _authHeaders).timeout(timeout),
      statusOf: (r) => r.statusCode,
    );
    if (resp.statusCode != 200) {
      // With an API key there is no retry, and a 401/403 is the key's. With a
      // password, [_sendWithAuthRetry] has just signed in again — a password
      // the server rejects fails there — so a 401/403 still standing is the
      // server refusing this account the request, not a wrong password.
      final rejectedKey =
          usesApiKey && (resp.statusCode == 401 || resp.statusCode == 403);
      throw RommException(
        'Request failed (${resp.statusCode})',
        statusCode: resp.statusCode,
        kind: rejectedKey ? RommFailure.invalidApiKey : RommFailure.serverError,
      );
    }
    return resp;
  }

  /// Reads a browse list from [resp] with [parse]. An answer that isn't the
  /// JSON RomM sends (a web page, or records of the wrong shape) is
  /// [RommFailure.notRomm] rather than a raw parse error.
  static T _parseBrowse<T>(http.Response resp, T Function(Object? json) parse) {
    try {
      return parse(jsonDecode(resp.body));
    } catch (e) {
      if (e is! FormatException && e is! TypeError) rethrow;
      // A FormatException's own text quotes the body; the excerpt holds it.
      final reason = e is FormatException ? e.message : '$e';
      throw RommException(
        'Server did not answer like RomM: $reason',
        serverResponse: _bodyExcerpt(resp.body),
        kind: RommFailure.notRomm,
      );
    }
  }

  /// Extracts the item list from a RomM list response, tolerating both a bare
  /// JSON array and a paginated `{items: [...]}` envelope. Any other shape
  /// (including `{}`) yields an empty list.
  static List<dynamic> _itemsOf(dynamic decoded) {
    if (decoded is List) return decoded;
    if (decoded is Map && decoded['items'] is List) {
      return decoded['items'] as List;
    }
    return const [];
  }

  /// Returns all platforms (consoles/systems) on the server.
  Future<List<RommPlatform>> getPlatforms() async {
    final resp = await _authedGet('/api/platforms');
    return _parseBrowse(resp, (decoded) {
      if (decoded is! List) return <RommPlatform>[];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(RommPlatform.fromJson)
          // RomM's /api/platforms returns every platform its DB knows about,
          // including ones with no scanned ROMs. Hide the empties.
          .where((p) => p.romCount > 0)
          .toList();
    });
  }

  /// Returns the current user's RetroAchievements progression as a map of
  /// RA game id → earned achievement count (`num_awarded`).
  ///
  /// RomM exposes per-user RA progress on the user (`GET /api/users/me` →
  /// `ra_progression.results`, each keyed by `rom_ra_id`), not on individual
  /// ROMs. Returns an empty map when the user hasn't linked/synced RA.
  Future<Map<int, int>> getRaProgression() async {
    final resp = await _authedGet('/api/users/me');
    return parseRaProgression(resp.body);
  }

  /// Parses `/api/users/me` JSON into a map of RA game id → earned count.
  /// Extracted for testability; tolerates missing/partial progression data.
  static Map<int, int> parseRaProgression(String body) {
    final result = <int, int>{};
    final decoded = jsonDecode(body);
    if (decoded is! Map) return result;
    final progression = decoded['ra_progression'];
    if (progression is! Map) return result;
    final results = progression['results'];
    if (results is! List) return result;
    for (final entry in results) {
      if (entry is! Map) continue;
      final gameId = (entry['rom_ra_id'] as num?)?.toInt();
      final awarded = (entry['num_awarded'] as num?)?.toInt();
      if (gameId != null && awarded != null) {
        result[gameId] = awarded;
      }
    }
    return result;
  }

  /// Returns the user's collections (`GET /api/collections`). Tolerates both a
  /// bare list and a `{items: [...]}` envelope; an empty/`{}` body yields [].
  Future<List<RommCollection>> getCollections() async {
    final resp = await _authedGet('/api/collections');
    return _parseBrowse(
      resp,
      (decoded) => _parseCollections(decoded, isVirtual: false),
    );
  }

  /// Returns RomM virtual collections of [type] (default `collection`, i.e. the
  /// auto-generated game-series groupings shown as "Collections" in RomM's UI).
  /// The endpoint requires the `type` query parameter.
  Future<List<RommCollection>> getVirtualCollections({
    String type = 'collection',
  }) async {
    final resp = await _authedGet(
      '/api/collections/virtual?type=${Uri.encodeQueryComponent(type)}',
    );
    return _parseBrowse(
      resp,
      (decoded) => _parseCollections(decoded, isVirtual: true),
    );
  }

  static List<RommCollection> _parseCollections(
    Object? decoded, {
    required bool isVirtual,
  }) {
    return _itemsOf(decoded)
        .whereType<Map<String, dynamic>>()
        .map((j) => RommCollection.fromJson(j, isVirtual: isVirtual))
        .toList();
  }

  /// Returns one page of ROMs filtered by exactly one of [platformId],
  /// [collectionId] (user collection) or [virtualCollectionId] (RomM virtual
  /// collection). RomM paginates via `limit`/`offset`; [search] filters by name
  /// server-side.
  ///
  /// Thin wrapper over [getRomsPage] for callers that only want the rows.
  Future<List<RommRom>> getRoms({
    int? platformId,
    int? collectionId,
    String? virtualCollectionId,
    String? search,
    int limit = 50,
    int offset = 0,
  }) async {
    final page = await getRomsPage(
      platformIds: platformId == null ? const [] : [platformId],
      collectionId: collectionId,
      virtualCollectionId: virtualCollectionId,
      search: search,
      limit: limit,
      offset: offset,
    );
    return page.items;
  }

  /// Returns the ROMs this user has played, most recent first.
  ///
  /// Ordering by `last_played` is also a *filter*: RomM leaves ROMs that have
  /// never been played out of the result entirely, so this returns a short
  /// candidate list rather than a page of the library. Measured against RomM
  /// 5.1.0 on a 9,899-ROM library, where it answered with 5.
  ///
  /// That is what makes the connect-time playtime pull affordable — one request
  /// names every ROM worth asking about, instead of a session lookup per linked
  /// game. `order_dir` must be passed explicitly: RomM defaults to ascending,
  /// which would return the *least* recently played.
  Future<List<RommRom>> getRecentlyPlayedRoms({int limit = 25}) async {
    final resp = await _authedGetUri(
      Uri.parse('$_baseUrl/api/roms').replace(
        queryParameters: <String, String>{
          'limit': '$limit',
          'offset': '0',
          'order_by': 'last_played',
          'order_dir': 'desc',
        },
      ),
    );
    return _parseBrowse(
      resp,
      (decoded) => _itemsOf(
        decoded,
      ).whereType<Map<String, dynamic>>().map(RommRom.fromJson).toList(),
    );
  }

  /// Returns one page of ROMs along with RomM's result [RommRomPage.total] and
  /// the filter values still available for the query.
  ///
  /// [genres] and [companies] are matched server-side across the whole library,
  /// so they narrow far more than post-filtering a fetched page can. Multiple
  /// values are OR-ed via RomM's `*_logic=any` default.
  ///
  /// Matching is exact and case-sensitive against RomM's own vocabulary:
  /// `Adventure` matches, `adventure` and `Advent` match nothing, and
  /// `Capcom` does not match a ROM credited to "Capcom Production Studio 1".
  /// Callers must therefore pass values RomM actually publishes — see the
  /// `filter_values` on [RommRomPage] — rather than values derived from a
  /// local library, which will silently return nothing when the two
  /// vocabularies disagree.
  ///
  /// Note RomM has no release-year filter — year has to stay a client-side
  /// concern.
  Future<RommRomPage> getRomsPage({
    List<int> platformIds = const [],
    int? collectionId,
    String? virtualCollectionId,
    String? search,
    List<String> genres = const [],
    List<String> companies = const [],
    int limit = 50,
    int offset = 0,
  }) async {
    // Repeated keys (platform_ids, genres, companies) need a list-valued map,
    // which Uri's queryParameters accepts as List<String>.
    final params = <String, dynamic>{
      'limit': '$limit',
      'offset': '$offset',
      'order_by': 'name',
    };
    if (platformIds.isNotEmpty) {
      // RomM filters by the plural `platform_ids`; `platform_id` is ignored.
      params['platform_ids'] = platformIds.map((id) => '$id').toList();
    }
    if (collectionId != null) {
      params['collection_id'] = '$collectionId';
    }
    if (virtualCollectionId != null) {
      params['virtual_collection_id'] = virtualCollectionId;
    }
    if (search != null && search.trim().isNotEmpty) {
      params['search_term'] = search.trim();
    }
    if (genres.isNotEmpty) params['genres'] = genres;
    if (companies.isNotEmpty) params['companies'] = companies;

    final resp = await _authedGetUri(
      Uri.parse('$_baseUrl/api/roms').replace(queryParameters: params),
    );
    return _parseBrowse(resp, (decoded) {
      // RomM may return either a bare list or a paginated `{items: [...]}`
      // object.
      final items = _itemsOf(
        decoded,
      ).whereType<Map<String, dynamic>>().map(RommRom.fromJson).toList();

      if (decoded is! Map<String, dynamic>) {
        return RommRomPage(items: items, total: items.length);
      }
      return RommRomPage(
        items: items,
        total: (decoded['total'] as num?)?.toInt() ?? items.length,
        filterValues: _filterValuesOf(decoded['filter_values']),
      );
    });
  }

  /// Normalizes RomM's `filter_values` object into string lists.
  ///
  /// `platforms` is dropped: it holds platform *ids*, not names, so it has no
  /// place alongside the string-valued dimensions.
  static Map<String, List<String>> _filterValuesOf(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, List<String>>{};
    for (final entry in raw.entries) {
      final key = entry.key.toString();
      if (key == 'platforms') continue;
      final value = entry.value;
      if (value is! List) continue;
      final values = [
        for (final v in value)
          if ((v?.toString() ?? '').trim().isNotEmpty) v.toString().trim(),
      ];
      if (values.isNotEmpty) out[key] = values;
    }
    return out;
  }

  /// Returns full detail for a single ROM.
  Future<RommRom> getRom(int id) async {
    final resp = await _authedGet('/api/roms/$id');
    return RommRom.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// Returns the raw ROM-detail JSON (metadata + media paths), or null on error.
  /// Used by the metadata import, which needs fields beyond [RommRom].
  Future<Map<String, dynamic>?> getRomDetail(int id) async {
    try {
      final resp = await _authedGet('/api/roms/$id');
      final decoded = jsonDecode(resp.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (e) {
      _log.e('RomM getRomDetail failed: $e');
      return null;
    }
  }

  /// Fetches raw image bytes (RomM-relative path or absolute URL), or null.
  /// The caller picks the on-disk extension from the actual content — RomM
  /// serves JPEG even from `*.png` cover paths, and the app's image lookup is
  /// extension-sensitive.
  ///
  /// With [requireImage] (the default) a body that isn't a recognisable image
  /// counts as a miss: a resource path RomM no longer has a file for falls
  /// through to its SPA shell, which answers **200 with HTML**. Writing that
  /// out would leave an undecodable `.png` behind — art that looks downloaded
  /// but renders as nothing — and would hide the miss from any caller trying a
  /// second source. Video fetches pass `requireImage: false`.
  Future<Uint8List?> fetchImageBytes(
    String pathOrUrl, {
    bool requireImage = true,
    bool quiet = false,
  }) async => (await fetchImage(
    pathOrUrl,
    requireImage: requireImage,
    quiet: quiet,
  )).bytes;

  /// [fetchImageBytes], but saying *why* there are no bytes.
  ///
  /// Callers that cache a negative answer need the distinction: only a
  /// [RommImageMiss.absent] result means "the server answered and there is
  /// nothing here". Everything else is the server being out of reach, and a
  /// caller that treats those alike turns a roaming handheld's momentary
  /// blackout into a permanent one.
  ///
  /// With [quiet] an *expected* miss is logged at debug rather than warning:
  /// the cover candidate list is walked in order, so a 404 on the first entry
  /// is the documented way to reach the second. [quiet] never applies to a
  /// [RommImageMiss.unreachable] outcome — the production logger runs at
  /// `Level.info`, so a debug line is dropped outright and a timeout or a TLS
  /// error on a cover would leave no trace at all in a support log.
  Future<RommImageFetch> fetchImage(
    String pathOrUrl, {
    bool requireImage = true,
    bool quiet = false,
  }) async {
    void absent(String message) => quiet ? _log.d(message) : _log.w(message);
    try {
      final url = pathOrUrl.startsWith('http')
          ? pathOrUrl
          : '$_baseUrl${pathOrUrl.startsWith('/') ? '' : '/'}$pathOrUrl';
      final resp = await _httpClient
          .get(Uri.parse(url), headers: imageHeadersFor(url))
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        // 404/410 are the server saying the file is not there. Anything else
        // — 5xx while it restarts, 401/403 before a token refresh, a proxy's
        // 502 — says nothing about the image, so it stays retryable.
        final gone = resp.statusCode == 404 || resp.statusCode == 410;
        final message = 'RomM image fetch: HTTP ${resp.statusCode} for $url';
        if (gone) {
          absent(message);
          return const RommImageFetch.missing(RommImageMiss.absent);
        }
        _log.w(message);
        return const RommImageFetch.missing(RommImageMiss.unreachable);
      }
      final bytes = resp.bodyBytes;
      if (requireImage && !looksLikeImage(bytes)) {
        // A 200 that isn't an image is still a definite answer: RomM served
        // its SPA shell because it has no file for this path.
        absent('RomM image fetch: non-image body for $url');
        return const RommImageFetch.missing(RommImageMiss.absent);
      }
      return RommImageFetch.found(bytes);
    } catch (e) {
      // Timeouts, SocketException, TLS handshake failures. Never demoted to
      // debug: `quiet` exists to mute expected candidate misses, not to hide
      // transport failures from the support log.
      if (quiet) {
        _log.w('RomM image fetch failed: $e');
      } else {
        _log.e('RomM image fetch failed: $e');
      }
      return const RommImageFetch.missing(RommImageMiss.unreachable);
    }
  }

  /// Cover URLs this server answered with nothing, so a tile does not re-ask
  /// for a dead end every time it is rebuilt.
  ///
  /// The grid keeps two rows either side of the viewport built and disposes
  /// the rest, so scrolling away and back gives a tile a fresh `State` with
  /// its candidate index at zero. For a library where RomM never cached small
  /// thumbnails that meant re-requesting the same 404 on every scrollback.
  ///
  /// On the service rather than in a static because it is a fact about *this
  /// server*: [configure] clears it, so pointing at a different RomM — or
  /// reconnecting after a rescan that filled the gaps — asks again. In memory
  /// only; nothing is written to disk.
  ///
  /// Only a [RommImageMiss.absent] answer belongs here — see [markDeadCover].
  final Set<String> _deadCovers = <String>{};

  /// Whether [url] already answered with nothing for the current server.
  bool isDeadCover(String url) => _deadCovers.contains(url);

  /// Ceiling on [_deadCovers], so the set cannot grow with the library.
  ///
  /// Worst case is one entry per candidate per ROM — three times the library
  /// size on a server that cached no covers at all — which is megabytes of
  /// strings on a handheld for a purely advisory optimisation. Past the cap we
  /// simply stop remembering; the overflow behaves the way everything did
  /// before this existed, which is a slower grid rather than a broken one.
  static const int maxRememberedDeadCovers = 4096;

  /// Records that [url] has no image behind it on this server.
  ///
  /// Callers MUST only pass a [RommImageMiss.absent] outcome. A timeout, a
  /// socket/TLS failure or a `5xx` is the server being unreachable, not the
  /// cover being missing, and remembering those would turn a Wi-Fi blip into a
  /// permanently grey grid.
  void markDeadCover(String url) {
    if (_deadCovers.length >= maxRememberedDeadCovers) return;
    _deadCovers.add(url);
  }

  /// Lets [urls] be asked for again: an explicit refresh retries artwork, and
  /// the server may have gained an image since it answered with nothing.
  void forgetDeadCovers(Iterable<String> urls) => _deadCovers.removeAll(urls);

  /// Whether [bytes] start with the magic numbers of an image format the app
  /// can decode. Deliberately content-based: RomM names every stored cover
  /// `big.png` whatever the source served, so the extension proves nothing.
  static bool looksLikeImage(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return true; // JPEG
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return true; // PNG
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return true; // WEBP
    }
    if (bytes.length >= 6 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38) {
      return true; // GIF
    }
    if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
      return true; // BMP
    }
    return false;
  }

  /// Returns the image file extension ('jpg'/'png'/'webp') implied by [bytes]'
  /// magic numbers, defaulting to 'png'.
  static String imageExtensionFor(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'jpg';
    }
    if (bytes.length >= 12 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'webp';
    }
    return 'png';
  }

  /// Builds an absolute, authenticated-fetchable cover URL for [rom], or null.
  String? coverUrl(RommRom rom) => coverUrlCandidates(rom).firstOrNull;

  /// Every cover URL [rom] could be drawn from, best first: the metadata
  /// provider's own copy, then RomM's cached large and small files.
  ///
  /// RomM populates these independently — a ROM matched without a provider
  /// cover still has the cached file, and a library RomM never cached covers
  /// for only has the provider URL. Anything that draws a cover should walk the
  /// list rather than give up on the first entry, or a ROM whose art the server
  /// plainly has renders as a blank card.
  List<String> coverUrlCandidates(RommRom rom) => _absoluteCoverUrls([
    rom.urlCover,
    rom.pathCoverLarge,
    rom.pathCoverSmall,
  ]);

  /// [coverUrlCandidates] reordered for grid and list tiles: RomM's cached
  /// small file first, then its large file, then the provider's copy.
  ///
  /// A tile is drawn at a fraction of a cover's native size, so the server's
  /// thumbnail is both the cheapest fetch (it is on the same LAN, and small)
  /// and the cheapest decode. Surfaces that show a single large cover keep
  /// [coverUrlCandidates].
  List<String> tileCoverUrlCandidates(RommRom rom) => _absoluteCoverUrls([
    rom.pathCoverSmall,
    rom.pathCoverLarge,
    rom.urlCover,
  ]);

  /// Absolute, authenticated-fetchable URLs for [covers] in the given order,
  /// skipping null/empty entries and joining server-relative paths onto the
  /// base URL.
  List<String> _absoluteCoverUrls(Iterable<String?> covers) {
    final urls = <String>[];
    for (final cover in covers) {
      if (cover == null || cover.isEmpty) continue;
      urls.add(
        (cover.startsWith('http://') || cover.startsWith('https://'))
            ? cover
            : '$_baseUrl${cover.startsWith('/') ? '' : '/'}$cover',
      );
    }
    return urls;
  }

  /// Absolute, authenticated-fetchable cover URLs making up [collection]'s
  /// mosaic thumbnail (up to [limit], RomM's web UI uses 4). Empty when the
  /// server reported no covers.
  List<String> collectionCovers(RommCollection collection, {int limit = 4}) {
    return collection.coverUrls
        .map((c) {
          if (c.startsWith('http://') || c.startsWith('https://')) return c;
          return '$_baseUrl${c.startsWith('/') ? '' : '/'}$c';
        })
        .take(limit)
        .toList();
  }

  /// Absolute logo URL for [platform] (usually a public IGDB CDN URL), or null.
  String? platformLogoUrl(RommPlatform platform) {
    final logo = platform.urlLogo;
    if (logo == null || logo.isEmpty) return null;
    if (logo.startsWith('http://') || logo.startsWith('https://')) {
      return logo;
    }
    return '$_baseUrl${logo.startsWith('/') ? '' : '/'}$logo';
  }

  /// Auth headers for fetching an image, but only when [url] points at the RomM
  /// server itself — never leak the bearer token to third-party CDNs (IGDB,
  /// RetroAchievements, etc. host many covers/logos).
  Map<String, String> imageHeadersFor(String url) {
    final uri = Uri.tryParse(url);
    return (_hasCredential && uri != null && _isConfiguredOrigin(uri))
        ? _authHeaders
        : const {};
  }

  /// Whether [uri] has exactly the configured server's origin — scheme, host
  /// and port — so credentials are never attached to any other server.
  bool _isConfiguredOrigin(Uri uri) {
    final base = Uri.tryParse(_baseUrl);
    if (base == null || !uri.hasScheme || uri.host.isEmpty) return false;
    return uri.scheme.toLowerCase() == base.scheme.toLowerCase() &&
        uri.host.toLowerCase() == base.host.toLowerCase() &&
        uri.port == base.port;
  }

  /// URL of RomM's bundled SVG icon for [platform]. RomM only ships icons for
  /// some slugs, so this may 404.
  String platformIconUrl(RommPlatform platform) =>
      '$_baseUrl/assets/platforms/${platform.slug}.svg';

  /// Fetches an SVG document, returning its source if it looks like SVG, else
  /// null (e.g. a 404 for a slug RomM has no icon for).
  ///
  /// RomM's icons are Illustrator exports that style shapes via `<style>` CSS
  /// classes, which flutter_svg ignores (everything would render solid black),
  /// so we inline those class styles as presentation attributes first.
  Future<String?> fetchSvg(String url) async {
    try {
      final resp = await _httpClient
          .get(Uri.parse(url), headers: imageHeadersFor(url))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200 && resp.body.contains('<svg')) {
        return _inlineSvgClassStyles(resp.body);
      }
    } catch (_) {
      // Network/parse failure: fall through to null so the UI uses a fallback.
    }
    return null;
  }

  /// Converts `<style>`-block class rules into inline presentation attributes so
  /// renderers without CSS support draw the intended fills/strokes. Handles
  /// multi-selector rules and elements carrying several classes.
  static String _inlineSvgClassStyles(String svg) {
    final styleMatch = RegExp(
      r'<style[^>]*>(.*?)</style>',
      dotAll: true,
    ).firstMatch(svg);
    if (styleMatch == null) return svg;

    final classProps = <String, Map<String, String>>{};
    final ruleRe = RegExp(r'([^{}]+)\{([^{}]+)\}');
    for (final rule in ruleRe.allMatches(styleMatch.group(1)!)) {
      final props = <String, String>{};
      for (final decl in rule.group(2)!.split(';')) {
        final i = decl.indexOf(':');
        if (i < 0) continue;
        final key = decl.substring(0, i).trim();
        final value = decl.substring(i + 1).trim();
        if (key.isNotEmpty && value.isNotEmpty) props[key] = value;
      }
      if (props.isEmpty) continue;
      for (final sel in rule.group(1)!.split(',')) {
        final s = sel.trim();
        if (!s.startsWith('.')) continue;
        classProps.putIfAbsent(s.substring(1), () => {}).addAll(props);
      }
    }
    if (classProps.isEmpty) return svg;

    return svg.replaceAllMapped(RegExp(r'class="([^"]+)"'), (m) {
      final merged = <String, String>{};
      for (final c in m.group(1)!.trim().split(RegExp(r'\s+'))) {
        final p = classProps[c];
        if (p != null) merged.addAll(p);
      }
      if (merged.isEmpty) return m.group(0)!;
      final attrs = merged.entries
          .map((e) => '${e.key}="${e.value}"')
          .join(' ');
      return '${m.group(0)} $attrs';
    });
  }

  // ── Download ─────────────────────────────────────────────────────────────

  /// How long [downloadRom] and [downloadAssetByPath] wait for the response
  /// headers.
  @visibleForTesting
  static const downloadRequestTimeout = Duration(seconds: 60);

  /// How long [downloadRom] and [downloadAssetByPath] wait for the next chunk
  /// of the body. There is no limit on the whole transfer: a multi-GB ROM over
  /// slow wifi is fine, as long as it keeps arriving.
  @visibleForTesting
  static const downloadStallTimeout = Duration(seconds: 60);

  /// [downloadRequestTimeout] for [downloadAssetByPath].
  final Duration assetRequestLimit;

  /// [downloadStallTimeout] for [downloadAssetByPath].
  final Duration assetStallLimit;

  /// How often [downloadRom] asks its `shouldCancel` while it waits on the
  /// server, so a cancel reaches a download that has stopped arriving.
  static const _cancelPollInterval = Duration(milliseconds: 250);

  /// Streams a ROM download to [destFilePath].
  ///
  /// Writes to a sibling `.part` temp file and renames it into place only on
  /// success, so partial/cancelled downloads never leave a usable-looking file.
  /// Streaming (not buffering) keeps memory flat for multi-GB ROMs.
  ///
  /// [onProgress] receives `(writtenBytes, totalBytes?)`. [shouldCancel] is
  /// polled between chunks, and every [_cancelPollInterval] while waiting on
  /// the server; returning true aborts with [RommCancelledException] and
  /// cleans up the temp file.
  ///
  /// The headers must arrive within [requestTimeout] and each chunk of the
  /// body within [stallTimeout] of the last, or the download fails with a
  /// [RommException]. A timeout, a cancel or any other failure aborts the
  /// request, which closes its connection.
  Future<void> downloadRom(
    RommRom rom, {
    required String destFilePath,
    void Function(int received, int? total)? onProgress,
    bool Function()? shouldCancel,
    Duration requestTimeout = downloadRequestTimeout,
    Duration stallTimeout = downloadStallTimeout,
  }) async {
    final fileName = rom.fsName.isNotEmpty ? rom.fsName : '${rom.id}';
    final endpoint =
        '/api/roms/${rom.id}/content/${Uri.encodeComponent(fileName)}';

    final tmpPath = '$destFilePath.part';
    final tmpFile = File(tmpPath);
    if (await tmpFile.exists()) {
      await tmpFile.delete();
    }
    await Directory(path.dirname(destFilePath)).create(recursive: true);

    // Completing [abort] tells the client to drop the request (and its
    // socket). It is shared by both attempts of the auth retry and completed
    // on every way out of this method; once the body has been read in full,
    // completing it has no effect.
    final abort = Completer<void>();
    void fireAbort() {
      if (!abort.isCompleted) abort.complete();
    }

    // Completes with null when [shouldCancel] says so. A plain value, never
    // an error, so a cancel that lands after the download has moved on is
    // nobody's unhandled exception. While the body streams, the poll also
    // cancels [chunks], which ends a pending `moveNext` with false: racing
    // every chunk against this future instead left a listener on it per
    // chunk, hundreds of megabytes over a large download.
    final cancelled = Completer<Never?>();
    StreamIterator<List<int>>? chunks;
    final cancelPoll = shouldCancel == null
        ? null
        : Timer.periodic(_cancelPollInterval, (_) {
            if (!cancelled.isCompleted && shouldCancel()) {
              cancelled.complete(null);
              chunks?.cancel();
            }
          });

    RandomAccessFile? part;
    // Only a failure while the body streams to disk is reported as a
    // "Download error"; anything else reaches the caller as it was thrown.
    var reading = false;
    try {
      // Opened before the request, so a folder that can't be written to fails
      // without asking for a body nobody would read: a body never listened to
      // keeps its connection open, aborted or not.
      try {
        part = await _openPartFile(tmpFile);
      } catch (e) {
        throw RommException('Download error: $e');
      }

      // Build a fresh request each attempt so the shared retry policy (401 →
      // refresh, 403 → re-auth) picks up the new token on its second try.
      final resp = await _sendWithAuthRetry<http.StreamedResponse>(() async {
        final sent = _httpClient
            .send(
              http.AbortableRequest(
                'GET',
                _uri(endpoint),
                abortTrigger: abort.future,
              )..headers.addAll(_authHeaders),
            )
            .timeout(requestTimeout);
        final answered = await Future.any<http.StreamedResponse?>([
          sent,
          cancelled.future,
        ]);
        if (answered == null) throw RommCancelledException();
        return answered;
      }, statusOf: (r) => r.statusCode);

      if (resp.statusCode != 200) {
        throw RommException(
          'Download failed (${resp.statusCode})',
          statusCode: resp.statusCode,
          serverResponse: await responseExcerpt(resp),
        );
      }

      final total = resp.contentLength;
      var received = 0;
      chunks = StreamIterator(resp.stream.timeout(stallTimeout));
      final out = part;
      reading = true;
      while (true) {
        final bool more;
        try {
          more = await chunks.moveNext();
          if (cancelled.isCompleted) throw RommCancelledException();
        } on TimeoutException {
          throw RommException(
            'Download stalled: no data for ${stallTimeout.inSeconds} s',
          );
        }
        if (!more) break;
        if (shouldCancel?.call() ?? false) throw RommCancelledException();
        final chunk = chunks.current;
        // Each chunk is on disk before the next is read. Handed to a sink
        // without waiting, a network faster than the disk (a microSD card, a
        // USB stick) piled the difference up in memory, gigabytes over a disc
        // image, and a failed write (a full disk) was lost, leaving the
        // download waiting for good. The body is paused meanwhile, which also
        // stops the stall timer: a slow disk is not a stalled server.
        await out.writeFrom(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await out.close();
      part = null;
      reading = false;

      // Replace any existing destination, then move temp into place.
      final destFile = File(destFilePath);
      if (await destFile.exists()) {
        await destFile.delete();
      }
      await tmpFile.rename(destFilePath);
      _log.i('RomM download complete: $destFilePath ($received bytes)');
    } catch (e) {
      fireAbort();
      try {
        await part?.close();
      } catch (_) {}
      try {
        if (await tmpFile.exists()) await tmpFile.delete();
      } catch (_) {}
      if (e is RommException || !reading) rethrow;
      throw RommException('Download error: $e');
    } finally {
      cancelPoll?.cancel();
      fireAbort();
      await chunks?.cancel();
    }
  }

  /// The content type and first [maxChars] characters of a failed [resp]'s
  /// body, whitespace collapsed. Reads at most 1 KiB for about [timeout] (at
  /// most twice that when the body stalls), then stops listening, which closes
  /// the connection, so a large, slow or never-ending error body can't stall
  /// the download flow. Best effort: answers what it got so far if reading
  /// fails.
  @visibleForTesting
  static Future<String> responseExcerpt(
    http.StreamedResponse resp, {
    int maxChars = 200,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    const maxBytes = 1024;
    final bytes = BytesBuilder(copy: false);
    final elapsed = Stopwatch()..start();
    var cut = false;
    try {
      // The stream timeout catches a body that stops arriving; the stopwatch
      // one that keeps arriving a byte at a time.
      await for (final chunk in resp.stream.timeout(timeout)) {
        final room = maxBytes - bytes.length;
        bytes.add(chunk.length > room ? chunk.sublist(0, room) : chunk);
        if (bytes.length >= maxBytes || elapsed.elapsed >= timeout) {
          cut = true;
          break;
        }
      }
    } catch (_) {}
    // The cut may split a multi-byte character.
    var text = utf8
        .decode(bytes.takeBytes(), allowMalformed: true)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.length > maxChars) {
      text = '${text.substring(0, maxChars)}…';
    } else if (cut) {
      text = '$text…';
    }
    final type = resp.headers['content-type'];
    return type == null ? text : '[$type] $text';
  }

  // ── Saves & states (asset sync) ──────────────────────────────────────────

  /// Lists the save files RomM holds for [romId] (`GET /api/saves?rom_id=`).
  Future<List<RommAsset>> listSaves({required int romId}) =>
      _listAssets('/api/saves', romId: romId, isState: false);

  /// Lists the save states RomM holds for [romId] (`GET /api/states?rom_id=`).
  Future<List<RommAsset>> listStates({required int romId}) =>
      _listAssets('/api/states', romId: romId, isState: true);

  /// Inventory for the Saves tab, including archival versions and backups.
  /// Unlike per-game sync discovery, this lists all of the current user's files.
  Future<List<RommAsset>> listSaveAssets() async {
    final results = await Future.wait([
      _listAssets('/api/saves', isState: false),
      _listAssets('/api/states', isState: true),
    ]);
    return [...results[0], ...results[1]];
  }

  Future<List<RommAsset>> _listAssets(
    String basePath, {
    int? romId,
    required bool isState,
  }) async {
    final resp = await _authedGet(
      romId == null ? basePath : '$basePath?rom_id=$romId',
    );
    return _itemsOf(jsonDecode(resp.body))
        .whereType<Map<String, dynamic>>()
        .map((j) => RommAsset.fromJson(j, isState: isState))
        .toList();
  }

  /// Downloads a save's bytes via the saves-only convenience route
  /// (`GET /api/saves/{id}/content`). Used by the generic [ISyncProvider] API
  /// which only has the asset id. For per-game sync prefer [downloadAssetByPath]
  /// (works for states too).
  Future<Uint8List> downloadSaveContent(int assetId) async {
    final resp = await _authedGet('/api/saves/$assetId/content');
    return resp.bodyBytes;
  }

  /// Downloads an asset's bytes from its server-relative [downloadPath]
  /// (`/api/raw/assets/{file_path}/{file_name}?timestamp=...`). This is the
  /// canonical route for BOTH saves and states — states have no `/content`
  /// endpoint.
  ///
  /// A state can be large, so there is no limit on the whole transfer: the
  /// headers must arrive within [assetRequestLimit] and each chunk of the
  /// body within [assetStallLimit] of the last, or the download fails as
  /// timed out and its request is aborted.
  Future<Uint8List> downloadAssetByPath(String downloadPath) async {
    final uri = _assetUri(downloadPath);
    // The request carries our credentials, so it may only go to the
    // configured server, whatever URL the server's listing returned.
    if (!_isConfiguredOrigin(uri)) {
      throw RommException('Asset is not on the configured RomM server');
    }

    // Reads the body inside the attempt, so a stall there is mapped like a
    // timeout waiting for the headers.
    Future<http.Response> send() async {
      final abort = Completer<void>();
      try {
        final resp = await _httpClient
            .send(
              http.AbortableRequest('GET', uri, abortTrigger: abort.future)
                ..headers.addAll(_authHeaders),
            )
            .timeout(assetRequestLimit);
        final body = await http.ByteStream(
          resp.stream.timeout(assetStallLimit),
        ).toBytes();
        return http.Response.bytes(
          body,
          resp.statusCode,
          headers: resp.headers,
          request: resp.request,
        );
      } finally {
        // Closes the connection of an attempt that failed; a body read in
        // full is unaffected.
        abort.complete();
      }
    }

    final resp = await _sendWithAuthRetry<http.Response>(
      send,
      statusOf: (r) => r.statusCode,
    );
    if (resp.statusCode != 200) {
      throw RommException(
        'Request failed (${resp.statusCode})',
        statusCode: resp.statusCode,
      );
    }
    return resp.bodyBytes;
  }

  /// Builds the request URI for a server-supplied asset [downloadPath].
  ///
  /// RomM emits this path **un-encoded** — raw file names and a raw timestamp
  /// — so it must be percent-encoded before use. [Uri.encodeFull] is wrong
  /// here: it leaves `#`/`?`/`&` intact (a save named `Zelda #1.srm` would lose
  /// its `#…` tail to a URL fragment → 404) and would double-escape any literal
  /// `%`. Instead the scheme/host is preserved verbatim while each path segment
  /// and query key/value is encoded individually, so plain-ASCII names come out
  /// byte-identical to the un-encoded input.
  Uri _assetUri(String downloadPath) {
    final String origin;
    final String rest; // path[?query], server-relative, still un-encoded
    if (downloadPath.startsWith('http')) {
      // Absolute URL: peel off scheme://authority (no raw specials live there),
      // keeping the raw path+query for manual encoding below.
      final slash = downloadPath.indexOf('/', downloadPath.indexOf('://') + 3);
      origin = slash == -1 ? downloadPath : downloadPath.substring(0, slash);
      rest = slash == -1 ? '' : downloadPath.substring(slash);
    } else {
      origin = _baseUrl;
      rest = downloadPath.startsWith('/') ? downloadPath : '/$downloadPath';
    }

    final q = rest.indexOf('?');
    final rawPath = q == -1 ? rest : rest.substring(0, q);
    final rawQuery = q == -1 ? null : rest.substring(q + 1);

    final encodedPath = rawPath.split('/').map(Uri.encodeComponent).join('/');
    final encodedQuery = rawQuery == null
        ? ''
        : '?${rawQuery.split('&').map((pair) {
            final eq = pair.indexOf('=');
            if (eq == -1) return Uri.encodeQueryComponent(pair);
            final k = Uri.encodeQueryComponent(pair.substring(0, eq));
            final v = Uri.encodeQueryComponent(pair.substring(eq + 1));
            return '$k=$v';
          }).join('&')}';

    return Uri.parse('$origin$encodedPath$encodedQuery');
  }

  /// Uploads [file] as a save for [romId] (`POST /api/saves`, field `saveFile`).
  ///
  /// [slot] is a stable *name* (RomM's own example is `autosave`), not a number.
  /// Passing one opts the save into RomM's `(rom_id, slot)` pairing — and into
  /// server-side renaming, since RomM datetime-tags every slotted upload.
  Future<RommAsset> uploadSave(
    int romId,
    File file, {
    String? emulator,
    String? slot,
    String? deviceId,
    bool overwrite = true,
  }) => _uploadAsset(
    '/api/saves',
    fileField: 'saveFile',
    romId: romId,
    file: file,
    emulator: emulator,
    slot: slot,
    deviceId: deviceId,
    overwrite: overwrite,
    isState: false,
  );

  /// Uploads [file] as a save state for [romId] (`POST /api/states`, field
  /// `stateFile`).
  ///
  /// [slot] is accepted for symmetry with [uploadSave] only — `/api/states` has
  /// no slot parameter, so RomM ignores it and never tags a state's filename.
  Future<RommAsset> uploadState(
    int romId,
    File file, {
    String? emulator,
    String? slot,
    String? deviceId,
    bool overwrite = true,
  }) => _uploadAsset(
    '/api/states',
    fileField: 'stateFile',
    romId: romId,
    file: file,
    emulator: emulator,
    slot: slot,
    deviceId: deviceId,
    overwrite: overwrite,
    isState: true,
  );

  /// Replaces the contents of the existing save asset [assetId]
  /// (`PUT /api/saves/{id}`, field `saveFile`).
  Future<RommAsset> updateSave(int assetId, File file) => _updateAsset(
    '/api/saves',
    fileField: 'saveFile',
    assetId: assetId,
    file: file,
    isState: false,
  );

  /// Replaces the contents of the existing state asset [assetId]
  /// (`PUT /api/states/{id}`, field `stateFile`).
  Future<RommAsset> updateState(int assetId, File file) => _updateAsset(
    '/api/states',
    fileField: 'stateFile',
    assetId: assetId,
    file: file,
    isState: true,
  );

  /// Updates an existing asset in place.
  ///
  /// This is deliberately not a `POST` with `overwrite=true`. RomM identifies an
  /// asset by `(rom_id, file_name)` and *ignores* `emulator` when matching, but
  /// it stores the file under the emulator label as a directory component. A
  /// `POST` from a device whose label differs from the one the asset was
  /// created with therefore updates the row's size and timestamp, writes its
  /// bytes to a different directory, and leaves `file_path` pointing at the
  /// original — so the download endpoint keeps serving the *old* file forever
  /// while the metadata describes the new one. Verified against RomM 5.1.0.
  ///
  /// `PUT` carries no emulator at all and rewrites the file at the path the
  /// asset already has, which keeps content and metadata in agreement.
  Future<RommAsset> _updateAsset(
    String basePath, {
    required String fileField,
    required int assetId,
    required File file,
    required bool isState,
  }) async {
    final uri = Uri.parse('$_baseUrl$basePath/$assetId');
    return _sendAssetFile(
      'PUT',
      uri,
      fileField: fileField,
      file: file,
      isState: isState,
      failure: 'Update failed',
    );
  }

  Future<RommAsset> _uploadAsset(
    String basePath, {
    required String fileField,
    required int romId,
    required File file,
    String? emulator,
    String? slot,
    String? deviceId,
    required bool overwrite,
    required bool isState,
  }) async {
    final params = <String, String>{
      'rom_id': '$romId',
      'overwrite': '$overwrite',
    };
    if (emulator != null && emulator.isNotEmpty) params['emulator'] = emulator;
    if (slot != null && slot.isNotEmpty) params['slot'] = slot;
    if (deviceId != null && deviceId.isNotEmpty) params['device_id'] = deviceId;
    final uri = Uri.parse(
      '$_baseUrl$basePath',
    ).replace(queryParameters: params);

    return _sendAssetFile(
      'POST',
      uri,
      fileField: fileField,
      file: file,
      isState: isState,
      failure: 'Upload failed',
    );
  }

  /// How long an upload waits for the connection to take the next chunk of
  /// the file. There is no limit on the whole transfer: a large state over a
  /// slow link is fine, as long as it keeps moving.
  ///
  /// The connection takes chunks in bursts, as the system's send buffer
  /// drains, not one by one: at 64 KiB/s about every 15 s. So this sets a
  /// floor, roughly 8 KiB/s, below which an upload that is still moving
  /// fails as timed out — well under any link a save would sync over.
  @visibleForTesting
  static const uploadStallTimeout = Duration(seconds: 120);

  /// How long an upload waits for the response headers once the whole file
  /// has been taken. Longer than [uploadStallTimeout]: the last chunk counts
  /// as taken once it reaches the send buffer, which can hold a few MB — a
  /// few minutes of a slow link — still to be sent.
  @visibleForTesting
  static const uploadResponseTimeout = Duration(seconds: 300);

  /// [uploadStallTimeout] for this service's uploads; also the limit between
  /// chunks of the response body.
  final Duration uploadStallLimit;

  /// [uploadResponseTimeout] for this service's uploads.
  final Duration uploadResponseLimit;

  /// Sends [file] as the multipart field [fileField] of a [method] request to
  /// [uri] and reads back the asset RomM answers with; a status other than
  /// 200/201 throws a [RommException] headed [failure].
  ///
  /// The transfer fails as timed out when it stops moving, not when it takes
  /// long: when the connection takes no chunk of the file for
  /// [uploadStallLimit] (a server that stops reading leaves the socket full,
  /// which pauses the file), when the headers take longer than
  /// [uploadResponseLimit] after the last chunk, or when the response body
  /// goes [uploadStallLimit] without a chunk. A timer measures that rather
  /// than `Stream.timeout`, which stops counting while its stream is paused —
  /// the very stall to catch.
  Future<RommAsset> _sendAssetFile(
    String method,
    Uri uri, {
    required String fileField,
    required File file,
    required bool isState,
    required String failure,
  }) async {
    // A fresh request, watchdog and abort for each attempt of the auth retry.
    // The answer is read inside the attempt too, so its timeout is mapped by
    // the retry like any other.
    Future<http.Response> send() async {
      final abort = Completer<void>();
      final timedOut = Completer<Never>();
      Timer? watchdog;
      var answered = false;
      var finished = false;
      StreamSubscription<List<int>>? reading;
      StreamSubscription<List<int>>? receiving;

      void arm(Duration limit) {
        // A chunk can still land after the attempt has ended.
        if (finished || timedOut.isCompleted) return;
        watchdog?.cancel();
        watchdog = Timer(limit, () {
          // The timeout goes in before the abort, so the race below ends with
          // it rather than with the client's report of the abort.
          timedOut.completeError(
            TimeoutException('RomM upload stalled', limit),
          );
          if (!abort.isCompleted) abort.complete();
        });
      }

      Future<http.Response> exchange() async {
        final length = await file.length();
        // Every chunk the connection takes from the file restarts the
        // watchdog. The read follows the request body's pauses, so it stops
        // when the socket does, and the watchdog, which nothing pauses, fires.
        late final StreamController<List<int>> content;
        content = StreamController<List<int>>(
          onListen: () => reading = file.openRead().listen(
            (chunk) {
              if (!answered) arm(uploadStallLimit);
              content.add(chunk);
            },
            onError: content.addError,
            onDone: () {
              if (!answered) arm(uploadResponseLimit);
              content.close();
            },
          ),
          onPause: () => reading?.pause(),
          onResume: () => reading?.resume(),
          onCancel: () => reading?.cancel(),
        );
        final req =
            http.AbortableMultipartRequest(
                method,
                uri,
                abortTrigger: abort.future,
              )
              ..headers.addAll(_authHeaders)
              ..files.add(
                http.MultipartFile(
                  fileField,
                  content.stream,
                  length,
                  filename: path.basename(file.path),
                ),
              );
        final resp = await _httpClient.send(req);
        answered = true;
        arm(uploadStallLimit);

        final body = BytesBuilder(copy: false);
        final received = Completer<void>();
        receiving = resp.stream.listen(
          (chunk) {
            arm(uploadStallLimit);
            body.add(chunk);
          },
          onError: received.completeError,
          onDone: received.complete,
          cancelOnError: true,
        );
        await received.future;
        return http.Response.bytes(
          body.takeBytes(),
          resp.statusCode,
          headers: resp.headers,
          request: resp.request,
        );
      }

      arm(uploadStallLimit);
      try {
        return await Future.any([exchange(), timedOut.future]);
      } finally {
        finished = true;
        watchdog?.cancel();
        // Closes the connection of an attempt that failed (a finished one is
        // unaffected) and the file, which the client may have left mid-read.
        if (!abort.isCompleted) abort.complete();
        unawaited(receiving?.cancel());
        await reading?.cancel();
      }
    }

    // Shared retry policy: 401 → refresh, 403 → re-auth (cached token may
    // predate the assets.write scope).
    final resp = await _sendWithAuthRetry<http.Response>(
      send,
      statusOf: (r) => r.statusCode,
    );
    if (resp.statusCode != 200 && resp.statusCode != 201) {
      throw RommException(
        '$failure (${resp.statusCode})',
        statusCode: resp.statusCode,
      );
    }
    return RommAsset.fromJson(
      jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>,
      isState: isState,
    );
  }

  /// Permanently deletes save files from the server (`POST /api/saves/delete`,
  /// body `{"saves": [...]}`). Requires the `assets.write` scope.
  Future<void> deleteSaves(List<int> assetIds) =>
      _deleteAssets('/api/saves', field: 'saves', assetIds: assetIds);

  /// Permanently deletes save states from the server
  /// (`POST /api/states/delete`, body `{"states": [...]}`).
  Future<void> deleteStates(List<int> assetIds) =>
      _deleteAssets('/api/states', field: 'states', assetIds: assetIds);

  /// RomM answers 404 when any id is not one of the current user's assets.
  Future<void> _deleteAssets(
    String basePath, {
    required String field,
    required List<int> assetIds,
  }) async {
    if (assetIds.isEmpty) return;
    final body = jsonEncode({field: assetIds});
    final resp = await _sendWithAuthRetry<http.Response>(
      () => _httpClient
          .post(
            _uri('$basePath/delete'),
            headers: {..._authHeaders, 'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(const Duration(seconds: 30)),
      statusOf: (r) => r.statusCode,
    );
    if (resp.statusCode != 200) {
      throw RommException(
        'Delete failed (${resp.statusCode})',
        statusCode: resp.statusCode,
      );
    }
  }

  // ── Play sessions (playtime sync) ─────────────────────────────────────────

  /// Uploads finished play sessions (`POST /api/play-sessions`).
  ///
  /// RomM caps a batch at 100 and dedupes on `(rom_id, start_time)`, so a
  /// re-push of a session it already holds is reported back as `duplicate`
  /// rather than added twice. Ingesting also moves the ROM's `last_played`
  /// forward server-side, which is why there's no separate props call.
  ///
  /// Throws [RommException]; a 404 (server predates the feature) or a 403 that
  /// survives the shared re-auth retry also disables further attempts for this
  /// connection — see [playtimeSyncAvailable].
  Future<RommPlaySessionIngestResult> ingestPlaySessions(
    List<RommPlaySession> sessions,
  ) async {
    if (sessions.isEmpty) {
      return const RommPlaySessionIngestResult(
        acceptedIndexes: {},
        rejectedIndexes: {},
        createdCount: 0,
        skippedCount: 0,
      );
    }
    if (sessions.length > maxPlaySessionBatch) {
      throw RommException(
        'Play-session batch exceeds RomM\'s limit of $maxPlaySessionBatch',
      );
    }

    final body = jsonEncode({
      'sessions': [for (final s in sessions) s.toIngestJson()],
    });

    final resp = await _sendWithAuthRetry<http.Response>(
      () => _httpClient
          .post(
            _uri('/api/play-sessions'),
            headers: {..._authHeaders, 'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(const Duration(seconds: 30)),
      statusOf: (r) => r.statusCode,
    );

    if (resp.statusCode != 200 && resp.statusCode != 201) {
      _notePlaySessionFailure(resp.statusCode);
      throw RommException(
        'Play-session upload failed (${resp.statusCode})',
        statusCode: resp.statusCode,
      );
    }

    final decoded = jsonDecode(resp.body);
    if (decoded is! Map<String, dynamic>) {
      throw RommException('Unexpected play-session response');
    }
    return RommPlaySessionIngestResult.fromJson(decoded);
  }

  /// Every play session the current user has for [romId], across all devices
  /// (`GET /api/play-sessions?rom_id=`).
  ///
  /// RomM only applies its default 50-row page cap when no time filter is
  /// given, so an epoch `start_after` is passed to get the complete history —
  /// the aggregate is meaningless if it silently stops at the newest 50.
  Future<List<RommPlaySession>> getPlaySessions({required int romId}) async {
    final uri = Uri.parse('$_baseUrl/api/play-sessions').replace(
      queryParameters: {
        'rom_id': '$romId',
        'start_after': '1970-01-01T00:00:00Z',
      },
    );

    final http.Response resp;
    try {
      resp = await _authedGetUri(uri);
    } on RommException catch (e) {
      if (e.statusCode != null) _notePlaySessionFailure(e.statusCode!);
      rethrow;
    }

    return _itemsOf(
      jsonDecode(resp.body),
    ).whereType<Map<String, dynamic>>().map(RommPlaySession.fromJson).toList();
  }

  /// Marks the play-session API unusable when the server's answer says it will
  /// never work on this connection: `404` (endpoint absent) or a `403` that has
  /// already survived one re-authentication, i.e. a genuine scope denial. In
  /// API-key mode a 403 is conclusive on the first try — the key's scopes were
  /// fixed when the user created it, so there is no re-auth that could widen
  /// them, and this is how a key issued without `roms.user.*` quietly settles
  /// into "everything but playtime sync" instead of erroring on every game exit.
  void _notePlaySessionFailure(int statusCode) {
    if (statusCode == 404 || statusCode == 403) {
      if (_playSessionsSupported) {
        _log.w(
          'RomM play-session API unavailable ($statusCode) — '
          'playtime sync disabled for this connection',
        );
      }
      _playSessionsSupported = false;
    }
  }
}
