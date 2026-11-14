import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/repositories/scraper_repository.dart';
import 'package:neostation/screens/game_screen/game_settings_dialog/game_settings_scrapping_tab.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/themes/chrome_surface.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

/// The "Rescrape from RomM" row in a game's Scrapping tab (NEO-109): it says
/// why it can't run (RomM not connected, game not linked), and otherwise asks
/// RomM for the game, by touch or from the controller.

const _snes = SystemModel(
  id: 'snes',
  folderName: 'snes',
  realName: 'Super Nintendo',
  iconImage: '',
  color: '#000000',
  folders: ['snes'],
);

const _game = GameModel(
  romname: 'Game (USA).sfc',
  realname: 'Game (USA)',
  name: 'Game (USA)',
  year: '',
  developer: '',
  publisher: 'Publisher when the dialog opened',
  genre: '',
  players: '',
  rating: 0,
  romPath: '/roms/snes/Game (USA).sfc',
  systemId: 'snes',
);

class _FakeRomm extends RommProvider {
  bool connected = false;
  RommRescrapeOutcome outcome = RommRescrapeOutcome.done;

  /// When set, a rescrape waits for it before answering [outcome].
  Completer<void>? hold;
  final calls = <(String, String)>[];

  @override
  bool get isConnected => connected;

  @override
  Future<RommRescrapeOutcome> rescrapeFromRomm(
    GameModel game,
    SystemModel system,
    FileProvider fileProvider,
  ) async {
    calls.add((game.romname, system.folderName));
    await hold?.future;
    return outcome;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final helper = DatabaseTestHelper();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
    SfxService().setEnabled(false);
  });

  late _FakeRomm romm;
  late int updates;
  final tabKey = GlobalKey<GameSettingsScrappingTabState>();

  setUp(() async {
    final db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    romm = _FakeRomm();
    updates = 0;
  });

  tearDown(() async => helper.tearDown());

  String en(String key) => AppLocale.en[key] as String;

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<RommProvider>.value(
        value: romm,
        child: ScreenUtilInit(
          designSize: const Size(640, 480),
          builder: (context, child) => MaterialApp(
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            theme: ThemeData(
              extensions: [ChromeSurface.standard(), CornerRadii.m()],
            ),
            home: Scaffold(
              body: GameSettingsScrappingTab(
                key: tabKey,
                game: _game,
                system: _snes,
                fileProvider: FileProvider(),
                isAllMode: false,
                onGameUpdated: () => updates++,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Presses the row and lets what it starts finish: the success path waits
  /// on real file and database work, which the test clock doesn't run.
  Future<void> press(
    WidgetTester tester,
    Future<void> Function() action,
  ) async {
    await tester.runAsync(action);
    // Real I/O and the test clock's microtasks take turns until it's done.
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
    }
  }

  Future<void> link() => RommSaveMapRepository.putMapping(
    source: RommLinkSource.auto,
    romname: 'Game (USA).sfc',
    systemFolder: 'snes',
    rommRomId: 42,
  );

  testWidgets('not connected to RomM: it says so and asks nothing', (
    tester,
  ) async {
    await link();
    await mount(tester);

    expect(find.text(en(AppLocale.rescrapeFromRomm)), findsOneWidget);
    expect(find.text(en(AppLocale.rommNotConnected)), findsOneWidget);
    await tester.tap(find.text(en(AppLocale.rescrapeFromRomm)));
    await tester.pumpAndSettle();
    expect(romm.calls, isEmpty);
  });

  testWidgets('a game not linked to RomM: it says so and asks nothing', (
    tester,
  ) async {
    romm.connected = true;
    await mount(tester);

    expect(find.text(en(AppLocale.rommLinkStateNotLinked)), findsOneWidget);
    await press(
      tester,
      () => tester.tap(find.text(en(AppLocale.rescrapeFromRomm))),
    );
    expect(romm.calls, isEmpty);
    expect(
      find.text(en(AppLocale.rommLinkStateNotLinked)),
      findsOneWidget,
      reason: 'the row went back from "Scraping…"',
    );
  });

  testWidgets('connected and linked: a tap rescrapes it from RomM', (
    tester,
  ) async {
    romm.connected = true;
    await link();
    await mount(tester);

    expect(find.text(en(AppLocale.rommNotConnected)), findsNothing);
    expect(find.text(en(AppLocale.rommLinkStateNotLinked)), findsNothing);
    await press(
      tester,
      () => tester.tap(find.text(en(AppLocale.rescrapeFromRomm))),
    );

    expect(romm.calls, [('Game (USA).sfc', 'snes')]);
    expect(updates, 1, reason: 'the game list refreshes the game');
  });

  testWidgets('a failure leaves the game as it was', (tester) async {
    romm.connected = true;
    romm.outcome = RommRescrapeOutcome.failed;
    await link();
    await mount(tester);

    await tester.tap(find.text(en(AppLocale.rescrapeFromRomm)));
    await tester.pumpAndSettle();

    expect(romm.calls, hasLength(1));
    expect(updates, 0);
  });

  testWidgets('from the controller: the third row, after Identify', (
    tester,
  ) async {
    romm.connected = true;
    await link();
    await mount(tester);

    final tab = tabKey.currentState!;
    tab.moveDown();
    tab.moveDown();
    await tester.pump();
    await press(tester, () async => tab.trigger());

    expect(romm.calls, hasLength(1));
  });

  testWidgets('linked in the Manage tab after the dialog opened: the press '
      'finds the link', (tester) async {
    romm.connected = true;
    await mount(tester);
    expect(find.text(en(AppLocale.rommLinkStateNotLinked)), findsOneWidget);

    await link();
    await press(
      tester,
      () => tester.tap(find.text(en(AppLocale.rescrapeFromRomm))),
    );

    expect(romm.calls, hasLength(1));
  });

  testWidgets('while it runs, Force Rescrape doesn\'t start', (tester) async {
    romm.connected = true;
    romm.hold = Completer<void>();
    await link();
    await mount(tester);

    await tester.tap(find.text(en(AppLocale.rescrapeFromRomm)));
    await tester.pump();
    final before = GlobalNotificationService().notifier.value.length;
    // Without a ScreenScraper account a Force Rescrape that starts posts a
    // notice at once; one that doesn't start posts nothing.
    await press(
      tester,
      () => tester.tap(find.text(en(AppLocale.forceRescrape))),
    );

    expect(
      GlobalNotificationService().notifier.value.length,
      before,
      reason: 'Force Rescrape started alongside',
    );
    romm.outcome = RommRescrapeOutcome.failed;
    romm.hold!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('the dialog closed while it runs: the game list still '
      'refreshes', (tester) async {
    romm.connected = true;
    romm.hold = Completer<void>();
    await link();
    await mount(tester);

    await tester.tap(find.text(en(AppLocale.rescrapeFromRomm)));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await press(tester, () async => romm.hold!.complete());

    expect(updates, 1);
  });

  testWidgets('with a row, the editor shows its values, not the game as it '
      'was when the dialog opened', (tester) async {
    await ScraperRepository.saveGameMetadata({
      'filename': 'Game (USA).sfc',
      'real_name': 'From the row',
    }, 'snes');
    await mount(tester);

    expect(find.text('Publisher when the dialog opened'), findsNothing);
  });

  testWidgets(
    'not busy, Force Rescrape does start (the busy test\'s control)',
    (tester) async {
      await mount(tester);
      final before = GlobalNotificationService().notifier.value.length;

      await press(
        tester,
        () => tester.tap(find.text(en(AppLocale.forceRescrape))),
      );

      expect(GlobalNotificationService().notifier.value.length, before + 1);
    },
  );

  testWidgets('saving edits takes the row out of ES-DE\'s hands', (
    tester,
  ) async {
    await ScraperRepository.saveGameMetadata({
      'filename': 'Game (USA).sfc',
      'real_name': 'Imported',
      'esde_imported': 1,
    }, 'snes');
    await mount(tester);

    final tab = tabKey.currentState!;
    for (var i = 0; i < 13; i++) {
      tab.moveDown();
    }
    await tester.pump();
    await press(tester, () async => tab.trigger());

    final row = await ScraperRepository.getGameMetadata(
      'snes',
      'Game (USA).sfc',
    );
    expect(row?['esde_imported'], 0);
  });
}
