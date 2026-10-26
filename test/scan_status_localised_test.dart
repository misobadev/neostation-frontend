import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';

/// The scan status — shown under the splash logo, on the scan card above the
/// systems grid, in the games list, in Settings > Directories and on the setup
/// wizard's scan step, on every platform — was set from fixed English strings ("Please Wait...",
/// "Waiting for ROM storage (1/10)...", "ROMs Scanned", …) whatever the app
/// language. The provider has no BuildContext, so the messages now come from
/// AppLocale through getStringForCurrentLocale().
void main() {
  // The provider library: the main file and every part of it.
  final sources = [
    File('lib/providers/sqlite_config_provider.dart'),
    ...Directory(
      'lib/providers/sqlite_config_provider',
    ).listSync().whereType<File>().where((f) => f.path.endsWith('.dart')),
  ];

  // `_scanStatus = 'Text` with a capital letter: a fixed message. Matched
  // across line breaks, so a literal `dart format` wrapped onto the next line
  // still counts. The empty reset and the list of system names being scanned
  // (data) are fine.
  final fixedText = RegExp(r"""_scanStatus\s*=\s*(['"])[A-Z][^'"]*""");

  test('the provider library has its files', () {
    expect(sources.length, greaterThan(1));
  });

  for (final file in sources) {
    test('${file.path} sets no fixed English scan status', () {
      final found = fixedText
          .allMatches(file.readAsStringSync())
          .map((m) => m.group(0))
          .toList();
      expect(found, isEmpty, reason: 'scan status must come from AppLocale');
    });
  }

  const newKeys = [
    AppLocale.waitingForRomStorage,
    AppLocale.updatingSystemsList,
    AppLocale.romsScanned,
    AppLocale.errorScanningRoms,
    AppLocale.romStorageNotReady,
  ];

  const translations = <String, Map<String, dynamic>>{
    'es': appLocaleEs,
    'pt': appLocalePt,
    'ru': appLocaleRu,
    'zh': appLocaleZh,
    'zh_Hant': appLocaleZhHant,
    'fr': appLocaleFr,
    'de': appLocaleDe,
    'it': appLocaleIt,
    'id': appLocaleId,
    'ja': appLocaleJa,
    'ko': appLocaleKo,
  };

  for (final entry in translations.entries) {
    test('${entry.key} translates the scan status messages', () {
      final untranslated = newKeys.where((k) {
        final value = entry.value[k];
        return value is! String || value.isEmpty || value == appLocaleEn[k];
      }).toList();
      expect(
        untranslated,
        isEmpty,
        reason: 'missing, empty or still English in this locale',
      );
    });
  }

  test('the storage wait keeps both counters in every language', () {
    for (final map in [appLocaleEn, ...translations.values]) {
      final value = map[AppLocale.waitingForRomStorage] as String;
      expect(value, contains('{attempt}'));
      expect(value, contains('{max}'));
    }
  });
}
