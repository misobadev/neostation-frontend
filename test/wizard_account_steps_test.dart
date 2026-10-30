import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/widgets/wizard_account_step.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The setup wizard's optional account steps: what each says, and which tabs a
/// new user's setup leaves hidden when RomM or save syncing is skipped.
void main() {
  group('tabs hidden after setup', () {
    test('nothing set up hides both RomM and Saves', () {
      final hidden = tabsHiddenAfterSetup(
        rommConnected: false,
        neoSyncSignedIn: false,
        savesUseRomm: false,
      );
      expect(hidden.hideRomm, isTrue);
      expect(hidden.hideSaves, isTrue);
    });

    test('NeoSync alone keeps Saves and hides RomM', () {
      final hidden = tabsHiddenAfterSetup(
        rommConnected: false,
        neoSyncSignedIn: true,
        savesUseRomm: false,
      );
      expect(hidden.hideRomm, isTrue);
      expect(hidden.hideSaves, isFalse);
    });

    test('RomM alone keeps RomM, and keeps Saves only when it holds saves', () {
      expect(
        tabsHiddenAfterSetup(
          rommConnected: true,
          neoSyncSignedIn: false,
          savesUseRomm: false,
        ),
        (hideRomm: false, hideSaves: true),
      );
      expect(
        tabsHiddenAfterSetup(
          rommConnected: true,
          neoSyncSignedIn: false,
          savesUseRomm: true,
        ),
        (hideRomm: false, hideSaves: false),
      );
    });
  });

  group('account step', () {
    Widget host(Widget child) => ScreenUtilInit(
      designSize: const Size(1280, 720),
      builder: (context, _) => MaterialApp(
        localizationsDelegates:
            FlutterLocalization.instance.localizationsDelegates,
        home: Scaffold(body: child),
      ),
    );

    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      await FlutterLocalization.instance.ensureInitialized();
      FlutterLocalization.instance.init(
        mapLocales: [MapLocale('en', AppLocale.en)],
        initLanguageCode: 'en',
      );
    });

    testWidgets('names the account once signed in', (tester) async {
      await tester.pumpWidget(
        host(
          const WizardAccountStep(
            icon: Symbols.trophy_rounded,
            title: 'RetroAchievements',
            description: 'desc',
            signedInAs: 'Pup',
            skipNote: 'note',
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Signed in as Pup'), findsOneWidget);
      expect(find.text('note'), findsNothing);
    });

    testWidgets('says what skipping costs while not signed in', (tester) async {
      await tester.pumpWidget(
        host(
          const WizardAccountStep(
            icon: Symbols.dns_rounded,
            title: 'RomM',
            description: 'desc',
            skipNote: 'the RomM tab stays hidden',
          ),
        ),
      );
      await tester.pump();
      expect(find.text('the RomM tab stays hidden'), findsOneWidget);
    });

    testWidgets('falls back to "set it up later" with no skip cost', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const WizardAccountStep(
            icon: Symbols.trophy_rounded,
            title: 'RetroAchievements',
            description: 'desc',
          ),
        ),
      );
      await tester.pump();
      expect(
        find.text(AppLocale.en[AppLocale.wizardAccountLater]! as String),
        findsOneWidget,
      );
    });
  });

  test('finishing hands save sync to NeoSync before choosing hidden tabs', () {
    // The RomM step comes before NeoSync's, and connecting RomM claims save
    // sync while NeoSync is signed out. A user who then signs in to NeoSync
    // expects their saves there.
    final wizard = File('lib/widgets/setup_wizard.dart').readAsStringSync();
    final start = wizard.indexOf('Future<void> _hideUnconfiguredTabs(');
    final body = wizard.substring(start, wizard.indexOf('\n  }\n', start));
    final release = body.indexOf('releaseIfActive(');
    expect(release, isNot(-1));
    expect(body.indexOf('RomMSyncProvider.kProviderId'), greaterThan(release));
    expect(
      body.indexOf('AuthService>().isLoggedIn'),
      lessThan(release),
      reason: 'only when NeoSync is signed in',
    );
    expect(release, lessThan(body.indexOf('tabsHiddenAfterSetup(')));
  });
}
