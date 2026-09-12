/// Secret redaction for anything written to the application log.
///
/// The log file lives on shared external storage and users routinely attach it
/// to public bug reports, so credentials must never reach it. Redaction is
/// applied centrally in [LoggerService] rather than at call sites: the leaks
/// that matter come from error objects we do not format ourselves — an HTTP
/// client exception, for example, embeds the full request URI including its
/// query string.
///
/// Kept pure and dependency-free so the patterns can be tested directly.
library;

/// Placeholder substituted for every redacted value.
const String redactedPlaceholder = '<redacted>';

/// Query-string parameters whose values are credentials.
///
/// `y` is the RetroAchievements web API key; `devpassword`/`sspassword` and
/// `devid`/`ssid` are the ScreenScraper developer and user credentials. The
/// rest are generic names used across the HTTP clients.
///
/// This list is only ever matched after a literal `?` or `&`, which is what
/// makes a name as short as `y` safe here. See [_sensitiveFieldNames].
const List<String> _sensitiveQueryParams = ['y', ..._sensitiveFieldNames];

/// Field names whose values are credentials in JSON / map / `toString` output.
///
/// Deliberately excludes `y`: unlike a query string there is no `?`/`&` to
/// anchor against, so a one-letter name matches inside ordinary prose. It is a
/// URL parameter of the RetroAchievements web API and never a field name.
///
/// Also deliberately excludes `authorization`: the value-bearing header already
/// matches [_authHeaderPattern] (which also redacts the scheme word, so the
/// `Bearer`/`Basic` marker survives), and adding the bare name here would make
/// [_jsonFieldPattern] swallow just the scheme and leave the token behind —
/// `Authorization: Bearer abc` would become `Authorization: <redacted> abc`.
/// The header name is not a credential shape on its own.
const List<String> _sensitiveFieldNames = [
  'api_key',
  'apikey',
  'access_token',
  'refresh_token',
  'auth',
  'client_secret_id',
  'credential',
  'devid',
  'devpassword',
  'key',
  'pass',
  'passwd',
  'password',
  'secret',
  'session',
  'sid',
  'sig',
  'signature',
  'ssid',
  'sspassword',
  'token',
];

/// `?y=abc` / `&password=abc` — keeps the parameter name, drops the value.
/// The value stops at the next separator so the rest of the URI is preserved.
final RegExp _queryParamPattern = RegExp(
  '([?&](?:${_sensitiveQueryParams.join('|')})=)([^&\\s"\'<>)\\]}]+)',
  caseSensitive: false,
);

/// `"password": "abc"` / `password: abc` in JSON or map/toString output.
///
/// The leading `(?<![A-Za-z0-9])` requires the name to start a word. Without
/// it, any word *ending* in a sensitive name scrubbed the token after it, which
/// silently mangled ordinary log lines — `Directory: /roms`, `Summary: 12`,
/// `Activity: com.foo.Bar`, `monkey: banana`, `bypass: true`. The `y` entry made
/// this pervasive (every word ending in "y"), which is why it now lives only in
/// [_sensitiveQueryParams].
///
/// `_` is deliberately NOT in that character class. Snake_case credential fields
/// are the common case in this codebase (SQLite columns, JSON payloads), and
/// excluding `_` would let `user_password: hunter2` through — a leak, and far
/// worse than over-redacting the occasional `first_pass: 3`.
///
/// The unquoted value must also stop at `&` and `<`: without that it runs past
/// the end of a query parameter and swallows the remainder of a URL, and it
/// re-matches an already-substituted `<redacted>`, breaking idempotence.
final RegExp _jsonFieldPattern = RegExp(
  '(?<![A-Za-z0-9])'
  '(["\']?(?:${_sensitiveFieldNames.join('|')})["\']?\\s*[:=]\\s*)'
  '(["\'][^"\']*["\']|[^,\\s}\\]&<>"\']+)',
  caseSensitive: false,
);

/// `Authorization: Bearer abc` and `Basic dXNlcjpwYXNz`.
final RegExp _authHeaderPattern = RegExp(
  r'((?:Bearer|Basic|Token)\s+)([A-Za-z0-9\-._~+/]+=*)',
  caseSensitive: false,
);

/// A JWT anywhere in the text, including ones we never named.
final RegExp _jwtPattern = RegExp(
  r'eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]+',
);

/// Credentials embedded in a URL's userinfo: `https://user:pass@host`.
final RegExp _urlUserInfoPattern = RegExp(r'(://)[^/\s:@]+:[^/\s@]+@');

/// Returns [text] with every recognised credential replaced by
/// [redactedPlaceholder].
///
/// Non-secret content is left untouched so the log stays useful for debugging:
/// usernames, hosts, paths and endpoint names all survive.
String redactSecrets(String text) {
  if (text.isEmpty) return text;

  var result = text.replaceAllMapped(
    _queryParamPattern,
    (m) => '${m[1]}$redactedPlaceholder',
  );
  result = result.replaceAllMapped(
    _jsonFieldPattern,
    (m) => '${m[1]}$redactedPlaceholder',
  );
  result = result.replaceAllMapped(
    _authHeaderPattern,
    (m) => '${m[1]}$redactedPlaceholder',
  );
  result = result.replaceAll(_jwtPattern, redactedPlaceholder);
  result = result.replaceAllMapped(
    _urlUserInfoPattern,
    (m) => '${m[1]}$redactedPlaceholder@',
  );
  return result;
}
