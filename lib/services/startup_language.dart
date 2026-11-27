import 'package:flutter/widgets.dart';

import '../l10n/app_locale.dart';

/// The app language for [locale]: its own when NeoStation has a translation
/// for it (Traditional Chinese by script or region), English otherwise.
String supportedLanguageFor(Locale locale) {
  const languages = AppLocale.supportedLanguages;
  if (locale.languageCode == 'zh') {
    final traditional =
        locale.scriptCode == 'Hant' ||
        const {'TW', 'HK', 'MO'}.contains(locale.countryCode);
    return traditional ? 'zh_Hant' : 'zh';
  }
  return languages.containsKey(locale.languageCode)
      ? locale.languageCode
      : 'en';
}
