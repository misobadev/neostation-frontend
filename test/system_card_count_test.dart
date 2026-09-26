import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/my_systems.dart';
import 'package:neostation/providers/neo_assets_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/screens/systems_screen/my_systems_section/system_card.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Covers the count the system card now carries in a pill over its artwork,
/// and the long-press that replaced the footer's Settings control.
///
/// Both moved for the same reason: the systems screen dropped its footer so
/// the cards could have that vertical space. The count was the only thing in
/// the footer nothing else said, and the Settings button was the only touch
/// route to a system's settings, so the card had to grow a label and a
/// gesture or the screen would have lost both.
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

  Widget host(
    SystemInfo info, {
    VoidCallback? onLongPress,
    bool showCount = true,
  }) => MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => NeoAssetsProvider()),
      ChangeNotifierProvider(create: (_) => SqliteConfigProvider()),
    ],
    child: ScreenUtilInit(
      designSize: const Size(1280, 720),
      builder: (context, _) => MaterialApp(
        // Without the delegates every `getString` resolves to
        // "<KEY> NOT FOUND" and each expectation below fails on a string
        // the app never renders.
        localizationsDelegates:
            FlutterLocalization.instance.localizationsDelegates,
        supportedLocales: FlutterLocalization.instance.supportedLocales,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 220,
              height: 260,
              child: SystemCard(
                info: info,
                onLongPress: onLongPress,
                showCount: showCount,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  SystemInfo system({
    required String folderName,
    required int count,
    String title = 'Card',
  }) => SystemInfo(
    title: title,
    shortName: title,
    folderName: folderName,
    numOfRoms: count,
    color1: '#7C4DFF',
  );

  group('SystemCard count', () {
    testWidgets('a system card names its game count', (tester) async {
      await tester.pumpWidget(host(system(folderName: 'nes', count: 12)));
      await tester.pump();
      expect(find.text('12 GAMES'), findsOneWidget);
    });

    testWidgets('the noun follows the folder', (tester) async {
      await tester.pumpWidget(host(system(folderName: 'android', count: 7)));
      await tester.pump();
      expect(find.text('7 APPS'), findsOneWidget);

      await tester.pumpWidget(host(system(folderName: 'music', count: 48)));
      await tester.pump();
      expect(find.text('48 TRACKS'), findsOneWidget);
    });

    testWidgets('the form flips at exactly one', (tester) async {
      await tester.pumpWidget(host(system(folderName: 'nes', count: 1)));
      await tester.pump();
      expect(find.text('1 GAME'), findsOneWidget);

      await tester.pumpWidget(host(system(folderName: 'nes', count: 2)));
      await tester.pump();
      expect(find.text('2 GAMES'), findsOneWidget);
    });

    testWidgets('a collection card counts games, not collections', (
      tester,
    ) async {
      // The Collections card sits in a row of cards that all answer "how many
      // games are in here", so it answers the same question (D17).
      await tester.pumpWidget(
        host(system(folderName: 'collection:abc', count: 4)),
      );
      await tester.pump();
      expect(find.text('4 GAMES'), findsOneWidget);
    });

    testWidgets('a missing count reads as zero rather than blank', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          SystemInfo(
            title: 'Empty',
            shortName: 'Empty',
            folderName: 'nes',
            color1: '#7C4DFF',
          ),
        ),
      );
      await tester.pump();
      expect(find.text('0 GAMES'), findsOneWidget);
    });

    testWidgets('the pill floats bottom left over the artwork', (tester) async {
      await tester.pumpWidget(host(system(folderName: 'nes', count: 12)));
      await tester.pump();

      final artwork = tester.getRect(find.byType(AspectRatio).first);
      final pill = tester.getRect(find.text('12 GAMES'));

      expect(pill.bottom, lessThanOrEqualTo(artwork.bottom));
      expect(pill.left, greaterThanOrEqualTo(artwork.left));
      expect(pill.center.dx, lessThan(artwork.center.dx));
    });

    testWidgets('costs the logo nothing', (tester) async {
      // The regression this guards: the count used to be a row under the
      // logo, and the logo is a FittedBox scaling into whatever that strip
      // has left. On the carousel the strip is only ~60px, so turning the
      // count on shrank every system logo by about a third. Floating the
      // pill over the artwork takes the count out of the layout entirely, so
      // the same card renders the same logo either way.
      Rect logoBand(WidgetTester tester) =>
          tester.getRect(find.byType(FittedBox));

      await tester.pumpWidget(
        host(system(folderName: 'nes', count: 12), showCount: false),
      );
      await tester.pump();
      final withoutCount = logoBand(tester);

      await tester.pumpWidget(host(system(folderName: 'nes', count: 12)));
      await tester.pump();

      expect(logoBand(tester), withoutCount);
    });

    testWidgets('is off unless the host asks for it', (tester) async {
      // The grid depends on this: its cards have no room for a count row, so
      // the count lives in that view's footer instead. Only the systems
      // carousel turns it on.
      await tester.pumpWidget(
        host(system(folderName: 'nes', count: 12), showCount: false),
      );
      await tester.pump();
      expect(find.text('12 GAMES'), findsNothing);
    });
  });

  group('SystemCard long press', () {
    testWidgets('opens the card menu', (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        host(system(folderName: 'nes', count: 3), onLongPress: () => opened++),
      );
      await tester.pump();

      await tester.longPress(find.byType(SystemCard));
      await tester.pump();

      expect(opened, 1);
    });

    testWidgets('a card with no menu has no long-press gesture', (
      tester,
    ) async {
      // Null must leave the card without the gesture rather than with an inert
      // one, so a host that has no menu cannot swallow the press.
      await tester.pumpWidget(host(system(folderName: 'nes', count: 3)));
      await tester.pump();

      final InkWell inkWell = tester.widget(find.byType(InkWell).first);
      expect(inkWell.onLongPress, isNull);
    });
  });
}
