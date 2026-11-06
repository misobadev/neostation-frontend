import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/user_data_location_service.dart';
import 'package:neostation/utils/user_data_move_failure_message.dart';

/// NEO-214: a failed move showed the exception's English text, "Exception:"
/// and all. Each kind now has its own message in the app language.
void main() {
  test('each kind has its own message', () {
    final keys = {
      for (final kind in UserDataMoveFailureKind.values)
        kind: userDataMoveFailureMessage(kind, (key) => key),
    };
    expect(keys, {
      UserDataMoveFailureKind.busy: AppLocale.userDataMoveBusy,
      UserDataMoveFailureKind.noSpace: AppLocale.userDataMoveNoSpace,
      UserDataMoveFailureKind.blocked: AppLocale.userDataMoveBlocked,
      UserDataMoveFailureKind.overlapping: AppLocale.userDataMoveOverlapping,
      // The wizard's message for the same problem.
      UserDataMoveFailureKind.notWritable: AppLocale.userDataFolderNotWritable,
      UserDataMoveFailureKind.other: AppLocale.userDataMoveFailed,
    });
  });

  test('every message is translated in every language', () {
    final languages = {
      'de': appLocaleDe,
      'en': appLocaleEn,
      'es': appLocaleEs,
      'fr': appLocaleFr,
      'id': appLocaleId,
      'it': appLocaleIt,
      'ja': appLocaleJa,
      'ko': appLocaleKo,
      'pt': appLocalePt,
      'ru': appLocaleRu,
      'zh': appLocaleZh,
      'zh_hant': appLocaleZhHant,
    };
    for (final kind in UserDataMoveFailureKind.values) {
      final key = userDataMoveFailureMessage(kind, (key) => key);
      for (final MapEntry(key: lang, value: map) in languages.entries) {
        final text = map[key];
        expect(text, isA<String>(), reason: '$lang lacks $key');
        expect(text, isNot(contains('Exception')), reason: '$lang $key');
        if (lang != 'en') {
          expect(
            text,
            isNot(appLocaleEn[key]),
            reason: '$lang $key is English',
          );
        }
      }
    }
  });
}
