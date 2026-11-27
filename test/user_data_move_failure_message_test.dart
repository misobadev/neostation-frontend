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
      // Settings' own wording: the wizard's adds "or keep the default
      // location", which doesn't fit once a custom folder is in use (NEO-68).
      UserDataMoveFailureKind.notWritable: AppLocale.userDataFolderCantWrite,
      UserDataMoveFailureKind.other: AppLocale.userDataMoveFailed,
    });
  });

  // NEO-68: on Android, a folder outside the app's own storage needs All
  // files access; Settings never said so.
  test("a folder that can't be written says how to allow it on Android", () {
    expect(
      userDataMoveFailureMessage(
        UserDataMoveFailureKind.notWritable,
        (key) => key,
        suggestAllFilesAccess: true,
      ),
      '${AppLocale.userDataFolderCantWrite}\n'
      '${AppLocale.userDataFolderGrantAllFiles}',
    );
    expect(
      userDataFolderNotWritableMessage(
        (key) => key,
        suggestAllFilesAccess: false,
      ),
      AppLocale.userDataFolderCantWrite,
    );
    // The hint is about access, so no other failure gets it.
    for (final kind in UserDataMoveFailureKind.values) {
      if (kind == UserDataMoveFailureKind.notWritable) continue;
      expect(
        userDataMoveFailureMessage(
          kind,
          (key) => key,
          suggestAllFilesAccess: true,
        ),
        userDataMoveFailureMessage(kind, (key) => key),
        reason: '$kind',
      );
    }
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
    for (final key in [
      for (final kind in UserDataMoveFailureKind.values)
        userDataMoveFailureMessage(kind, (key) => key),
      AppLocale.userDataFolderGrantAllFiles,
      AppLocale.wizardFolderNotUsable,
    ]) {
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
