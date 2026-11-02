import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/utils/neosync_failure_message.dart';

/// A NeoSync request that never reached the server showed the client's English
/// "Network error: …" text whatever the app language. It now says the server
/// couldn't be reached, in the app language; what the server itself said is
/// still shown as it was.
void main() {
  String english(String key) => AppLocale.en[key] as String;

  test('a request that never reached NeoSync says so in the app '
      'language', () {
    final result = {
      'success': false,
      'message': 'Network error: TimeoutException after 0:00:15.000000',
      'isNetworkError': true,
    };

    expect(
      neoSyncFailureMessage(result, english),
      "Couldn't reach NeoSync. Check your connection and try again.",
    );
    expect(
      neoSyncFailureMessage(result, (key) => AppLocale.de[key] as String),
      AppLocale.de[AppLocale.neoSyncUnreachable],
    );
  });

  test('a billing change NeoSync did not confirm says it may have gone '
      'through, not that NeoSync was out of reach', () {
    final result = {
      'success': false,
      'message': 'Network error: TimeoutException after 0:00:15.000000',
      'isNetworkError': true,
      'outcomeUnknown': true,
    };

    expect(
      neoSyncFailureMessage(result, english),
      "NeoSync didn't confirm the change in time. It may still have gone "
      'through, so check your plan before trying again.',
    );
    expect(
      neoSyncFailureMessage(result, (key) => AppLocale.de[key] as String),
      AppLocale.de[AppLocale.neoSyncBillingUnconfirmed],
    );
  });

  test("the server's own message is passed on as it was", () {
    final result = {'success': false, 'message': 'Invalid credentials'};

    expect(neoSyncFailureMessage(result, english), 'Invalid credentials');
  });

  test('with no message, the fallback is used', () {
    expect(
      neoSyncFailureMessage({'success': false}, english, fallback: 'Error'),
      'Error',
    );
    expect(neoSyncFailureMessage({'success': false}, english), isNull);
  });

  test('every screen that shows a NeoSync failure goes through it', () {
    for (final path in [
      'lib/widgets/auth_form.dart',
      'lib/screens/neo_sync_screen/login_screen/neo_sync_content.dart',
      'lib/screens/neo_sync_screen/login_screen/plan_selection_view.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, contains('neoSyncFailureMessage('), reason: path);
      expect(
        source,
        isNot(contains("result['message']")),
        reason: '$path shows a service message without the helper',
      );
    }
  });

  test('every language has the messages', () {
    for (final key in [
      AppLocale.neoSyncUnreachable,
      AppLocale.neoSyncBillingUnconfirmed,
    ]) {
      for (final map in [
        AppLocale.de,
        AppLocale.es,
        AppLocale.fr,
        AppLocale.id,
        AppLocale.it,
        AppLocale.ja,
        AppLocale.ko,
        AppLocale.pt,
        AppLocale.ru,
        AppLocale.zh,
        AppLocale.zhHant,
      ]) {
        final text = map[key];
        expect(text, isA<String>(), reason: key);
        expect(text, isNot(AppLocale.en[key]), reason: key);
        expect(text, contains('NeoSync'), reason: key);
      }
    }
  });
}
