import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/screens/neo_sync_screen/login_screen/custom_save_folders_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// NEO-285: a standalone folder's upload also leaves saves for their game's
/// next launch (the game may still be open in an emulator, or the emulator
/// wrote its old save back over a launch's download). Its message says so on
/// its own line, apart from the memory cards never synced from this device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });

  String en(String key) => AppLocale.en[key] as String;

  Future<String> message(
    WidgetTester tester, {
    int cards = 0,
    int saves = 0,
  }) async {
    late String shown;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates:
            FlutterLocalization.instance.localizationsDelegates,
        supportedLocales: FlutterLocalization.instance.supportedLocales,
        home: Builder(
          builder: (context) {
            shown = customFolderUploadedMessage(
              context,
              uploaded: 2,
              skipped: 1,
              cardsLeftForLaunch: cards,
              savesLeftForLaunch: saves,
            );
            return const SizedBox();
          },
        ),
      ),
    );
    return shown;
  }

  final complete = AppLocale.en[AppLocale.customFolderUploadComplete]
      .toString()
      .replaceFirst('{uploaded}', '2')
      .replaceFirst('{skipped}', '1');

  testWidgets('saves left for their game\'s launch get their own line', (
    tester,
  ) async {
    expect(
      await message(tester, saves: 3),
      '$complete\n'
      '${en(AppLocale.customFolderUploadSavesLeftForLaunch).replaceFirst('{left}', '3')}',
    );
  });

  testWidgets('with none, the line isn\'t shown', (tester) async {
    expect(await message(tester), complete);
  });

  testWidgets('memory cards and saves each keep their own line', (
    tester,
  ) async {
    expect(
      await message(tester, cards: 1, saves: 2),
      '$complete\n'
      '${en(AppLocale.customFolderUploadLeftForLaunch).replaceFirst('{left}', '1')}\n'
      '${en(AppLocale.customFolderUploadSavesLeftForLaunch).replaceFirst('{left}', '2')}',
    );
  });
}
