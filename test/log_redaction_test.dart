import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/log_redaction.dart';

void main() {
  group('redactSecrets — the observed leak', () {
    test('strips the RetroAchievements web API key from a request URI', () {
      // Shape of the line seen in app.log on the Thor: the key is in the URI
      // carried by an http ClientException, not in our own message.
      // NOTE: the key below is a dummy of the same shape (32 chars, base62) —
      // never paste a real key here, this file is public.
      const fakeKey = 'EXAMPLEexample0123456789ABCDefgh';
      const line =
          'Error getting user profile: ClientException with SocketException: '
          'Failed host lookup, uri=https://retroachievements.org/API/'
          'API_GetUserProfile.php?u=SomeUser&y=$fakeKey';

      final redacted = redactSecrets(line);

      expect(redacted, isNot(contains(fakeKey)));
      expect(redacted, contains('y=<redacted>'));
      // Everything needed to debug the failure survives.
      expect(redacted, contains('u=SomeUser'));
      expect(redacted, contains('API_GetUserProfile.php'));
      expect(redacted, contains('Failed host lookup'));
    });

    test('strips ScreenScraper developer and user credentials', () {
      const line =
          'GET https://api.screenscraper.fr/api2/jeuInfos.php?devid=neo'
          '&devpassword=s3cr3t&softname=NeoStation&ssid=someone'
          '&sspassword=hunter2&output=json';

      final redacted = redactSecrets(line);

      expect(redacted, isNot(contains('s3cr3t')));
      expect(redacted, isNot(contains('hunter2')));
      expect(redacted, isNot(contains('=neo&')));
      expect(redacted, contains('devpassword=<redacted>'));
      expect(redacted, contains('sspassword=<redacted>'));
      expect(redacted, contains('softname=NeoStation'));
      expect(redacted, contains('output=json'));
    });
  });

  group('redactSecrets — other credential shapes', () {
    test('redacts a bearer token', () {
      final redacted = redactSecrets(
        'headers: {Authorization: Bearer abc123DEF456ghi}',
      );
      expect(redacted, isNot(contains('abc123DEF456ghi')));
      expect(redacted, contains('Bearer <redacted>'));
    });

    test('redacts a JWT anywhere in the text', () {
      const jwt =
          'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9'
          '.eyJzdWIiOiIxMjM0NTY3ODkwIn0'
          '.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      final redacted = redactSecrets('NeoSync session restored: $jwt');
      expect(redacted, isNot(contains('eyJhbGci')));
      expect(redacted, contains('<redacted>'));
      expect(redacted, contains('NeoSync session restored'));
    });

    test('redacts credentials embedded in a URL', () {
      final redacted = redactSecrets(
        'RomM: connecting to https://user:hunter2@romm.local/api/roms',
      );
      expect(redacted, isNot(contains('hunter2')));
      expect(redacted, contains('https://<redacted>@romm.local/api/roms'));
    });

    test('redacts credential-shaped JSON fields', () {
      final redacted = redactSecrets(
        'body: {"username": "someone", "password": "hunter2", '
        '"token": "abc.def"}',
      );
      expect(redacted, isNot(contains('hunter2')));
      expect(redacted, isNot(contains('abc.def')));
      expect(redacted, contains('someone'));
    });

    test('is case-insensitive about parameter names', () {
      final redacted = redactSecrets('?API_KEY=abc123&Password=xyz789');
      expect(redacted, isNot(contains('abc123')));
      expect(redacted, isNot(contains('xyz789')));
    });

    test('redacts a credential-shaped field', () {
      final redacted = redactSecrets(
        'OAuth: credential=abc.def.ghi, client_secret_id=hunter2',
      );
      expect(redacted, isNot(contains('abc.def.ghi')));
      expect(redacted, isNot(contains('hunter2')));
      expect(redacted, contains('client_secret_id=<redacted>'));
    });

    test('redacts a Set-Cookie session id', () {
      final redacted = redactSecrets('Set-Cookie: sid=abc123secret');
      expect(redacted, isNot(contains('abc123secret')));
      expect(redacted, contains('sid=<redacted>'));
    });

    test(
      'an Authorization header still redacts the token, not just the scheme',
      () {
        // `authorization` is deliberately NOT in the field-name set: if it were,
        // the JSON-field pattern would swallow only "Bearer" and leave the token.
        // The auth-header pattern must therefore carry the whole value.
        final redacted = redactSecrets(
          'headers: {Authorization: Bearer abc123DEF456ghi}',
        );
        expect(redacted, isNot(contains('abc123DEF456ghi')));
        expect(redacted, contains('Bearer <redacted>'));
      },
    );
  });

  group('redactSecrets — NeoSync auth failure reaching the sign-in screen', () {
    // What the sign-in screen can render today: auth_service returns the server
    // `error` body and the raw exception verbatim. Both must be clean before
    // they ever reach auth_form's message box.
    test('redacts credentials embedded in the network error URI', () {
      const line =
          'Network error: ClientException with SocketException: '
          'Failed host lookup, uri=https://admin:hunter2@auth.neosync.cloud/login';
      final redacted = redactSecrets(line);

      expect(redacted, isNot(contains('hunter2')));
      expect(redacted, isNot(contains('admin:hunter2')));
      // The diagnostics needed to debug a failed login survive.
      expect(redacted, contains('auth.neosync.cloud/login'));
      expect(redacted, contains('Failed host lookup'));
    });

    test('redacts a credential-carrying server error body', () {
      const line = 'Invalid credentials for user admin, api_key=abc123DEF456';
      final redacted = redactSecrets(line);

      expect(redacted, isNot(contains('abc123DEF456')));
      expect(redacted, contains('api_key=<redacted>'));
      // The server's plain-language reason is still readable.
      expect(redacted, contains('Invalid credentials for user admin'));
    });
  });

  group('redactSecrets — leaves ordinary logs alone', () {
    test('does not touch a normal message', () {
      const line = 'Database loaded: 35 systems with games';
      expect(redactSecrets(line), line);
    });

    test('does not touch a plain path or non-secret query', () {
      const line =
          'Scanning /storage/emulated/0/roms/nes — '
          'https://example.com/manifest.json?v=2&platform=android';
      expect(redactSecrets(line), line);
    });

    test('handles an empty string', () {
      expect(redactSecrets(''), '');
    });

    test('redaction is idempotent', () {
      const line = 'uri=https://retroachievements.org/API/x.php?u=me&y=SECRET';
      final once = redactSecrets(line);
      expect(redactSecrets(once), once);
    });
  });

  group('redactSecrets — does not eat ordinary words (false positives)', () {
    // Every sensitive name was matched without a leading word boundary, so any
    // word *ending* in one of them scrubbed the following token. Observed live:
    // "[EmuSel] ANOMALY: system ds has 2 user defaults" lost the word "system"
    // because "ANOMALY" ends in "y", the RetroAchievements API key parameter.
    const survivors = <String, String>{
      'ANOMALY: system ds has 2 user defaults': 'system',
      'Summary: 12 games scanned': '12',
      'Directory: /storage/emulated/0/roms': '/storage/emulated/0/roms',
      'Activity: com.retroarch.browser.RetroActivity':
          'com.retroarch.browser.RetroActivity',
      'Query: SELECT * FROM user_roms': 'SELECT',
      'Priority: high': 'high',
      'Body: null': 'null',
      'monkey: banana': 'banana',
      'bypass: true': 'true',
      'oauth: disabled': 'disabled',
    };

    survivors.forEach((line, mustSurvive) {
      test('leaves "$line" alone', () {
        final redacted = redactSecrets(line);
        expect(redacted, contains(mustSurvive));
        expect(redacted, isNot(contains(redactedPlaceholder)));
      });
    });
  });

  group('redactSecrets — still redacts real credentials', () {
    test('a standalone key/token/password field is still redacted', () {
      for (final line in [
        'key: abc123',
        'token: abc123',
        'password: abc123',
        'secret = abc123',
        '"api_key": "abc123"',
      ]) {
        final redacted = redactSecrets(line);
        expect(redacted, isNot(contains('abc123')), reason: line);
        expect(redacted, contains(redactedPlaceholder), reason: line);
      }
    });

    test('the RA api key is still redacted as a query parameter', () {
      final redacted = redactSecrets('https://ra.org/API/x.php?u=me&y=SECRET1');
      expect(redacted, isNot(contains('SECRET1')));
      expect(redacted, contains('y=<redacted>'));
    });
  });

  group('redactSecrets — snake_case credential fields', () {
    // The word-boundary that fixes the false positives must NOT treat `_` as a
    // word character: snake_case is how credentials appear in SQLite columns
    // and JSON payloads here, and excluding `_` silently un-redacted them.
    test('a snake_case credential field is still redacted', () {
      for (final line in [
        'user_password: hunter2',
        'ra_key: hunter2',
        'dev_password=hunter2',
        '{ss_password: hunter2}',
        '"refresh_token": "hunter2"',
      ]) {
        final redacted = redactSecrets(line);
        expect(redacted, isNot(contains('hunter2')), reason: line);
        expect(redacted, contains(redactedPlaceholder), reason: line);
      }
    });
  });
}
