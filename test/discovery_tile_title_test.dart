import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/database_game_model.dart';
import 'package:neostation/models/discovery_models.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/screens/discovery_screen/discovery_mosaic.dart';
import 'package:neostation/screens/discovery_screen/widgets/discovery_tile.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests for what a Discovery card prints.
///
/// The game's own name belongs to the screen footer; the card carries only the
/// section name, set large and bold where a system card puts its logo.
const _gameName = 'Garou: Mark of the Wolves';

DiscoveryTile _tile() => DiscoveryTile(
  kind: DiscoveryTileKind.grid,
  labelKey: AppLocale.genreFighting,
  icon: Symbols.sports_martial_arts_rounded,
  entry: DiscoveryBoardEntry(
    pick: const DiscoveryPick(
      weekKey: '2026-W33',
      slotId: 'genre:fighting',
      section: DiscoverySection.genrePick,
      romPath: '/roms/neogeo/garou.zip',
    ),
    // No system folder, so the card draws its placeholder rather than asking
    // the file provider for art.
    game: DatabaseGameModel(
      filename: 'garou.zip',
      romPath: '/roms/neogeo/garou.zip',
      realName: _gameName,
    ),
  ),
);

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

  Future<void> mount(WidgetTester tester, {bool isSelected = false}) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1920, 1080)),
        child: ScreenUtilInit(
          designSize: const Size(640, 480),
          builder: (context, child) => MaterialApp(
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            theme: ThemeData(extensions: [CornerRadii.m()]),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 360,
                  height: 300,
                  child: DiscoveryCard(
                    tile: _tile(),
                    isSelected: isSelected,
                    fileProvider: FileProvider(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('shows the section name in the card footer', (tester) async {
    await mount(tester);
    expect(find.text('FIGHTING'), findsOneWidget);
  });

  testWidgets('does not print the game name on the card', (tester) async {
    await mount(tester);
    expect(find.text(_gameName), findsNothing);
  });

  testWidgets('sets the section name in bold', (tester) async {
    await mount(tester);
    final label = tester.widget<Text>(find.text('FIGHTING'));
    expect(label.style?.fontWeight, FontWeight.w900);
  });
}
