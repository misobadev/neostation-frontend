import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/collections_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/screens/game_screen/game_list_view.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/sync/i_sync_provider.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:neostation/widgets/neo_sync_status_icon.dart';

/// The cloud-sync mark lives on the game list's selected row.
///
/// It has been a marker at the end of the details card's metadata line, then a
/// chip in that card's control row. Both of those are places to look *away from
/// the selection* for something that is only ever true of the selected game,
/// and the chip was charging the achievements pill — the row's only Expanded —
/// a control's width to say it.
///
/// On the row it is the same size and colour rule as the marks already there
/// (the collection diamond, the achievements trophy), and it draws on exactly
/// one row: the one the cursor is on.
class _FakeSync implements ISyncProvider {
  _FakeSync(this._status);

  final GameSyncStatus _status;

  @override
  String get providerId => 'neosync';

  @override
  bool get isAuthenticated => true;

  @override
  SyncProviderStatus get status => SyncProviderStatus.connected;

  @override
  String? get lastError => null;

  @override
  GameSyncState? getGameSyncState(String gameId) => GameSyncState(
    gameId: gameId,
    gameName: gameId,
    status: _status,
    cloudEnabled: true,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

GameModel _game(String romname, String name) => GameModel(
  romname: romname,
  realname: name,
  name: name,
  year: '',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 0,
  cloudSyncEnabled: true,
);

final _games = [
  _game('mario.sfc', 'Super Mario World'),
  _game('zelda.sfc', 'A Link to the Past'),
  _game('metroid.sfc', 'Super Metroid'),
];

SystemModel _system({bool sync = true, int? screenscraperId = 4}) =>
    SystemModel(
      id: 'snes',
      folderName: 'snes',
      realName: 'Super Nintendo',
      iconImage: '',
      color: '#ff006a',
      screenscraperId: screenscraperId,
      neosync: NeoSyncConfig(
        sync: sync,
        androidSyncFolder: const [],
        windowsSyncFolder: const [],
        linuxSyncFolder: const [],
        macosSyncFolder: const [],
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('xyz.luan/gamepads'),
          (call) async => <dynamic>[],
        );

    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
    SfxService().setEnabled(false);
  });

  /// [SyncManager] is a singleton with a private constructor, so the fake is
  /// registered on the real one and taken back out afterwards.
  void useProvider(ISyncProvider? provider) {
    SyncManager.instance.unregister('neosync');
    if (provider != null) SyncManager.instance.register(provider);
    addTearDown(() => SyncManager.instance.unregister('neosync'));
  }

  Future<void> pumpList(
    WidgetTester tester, {
    int selectedIndex = 1,
    SystemModel? system,
    Size designSize = const Size(1920, 1080),
  }) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1920, 1080)),
        child: ScreenUtilInit(
          designSize: designSize,
          builder: (context, child) => MaterialApp(
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: MultiProvider(
              providers: [
                ChangeNotifierProvider<SqliteConfigProvider>(
                  create: (_) => SqliteConfigProvider(),
                ),
                ChangeNotifierProvider<CollectionsProvider>(
                  create: (_) => CollectionsProvider(),
                ),
                ChangeNotifierProvider<SyncManager>.value(
                  value: SyncManager.instance,
                ),
              ],
              child: Scaffold(
                body: GameListView(
                  system: system ?? _system(),
                  games: _games,
                  selectedIndex: selectedIndex,
                  systemColor: Colors.pink,
                  onGameSelected: (_) {},
                  onGameConfirmed: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // MarqueeText scrolls forever, so pumpAndSettle would never return.
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Drains the centering-scroll timer the list schedules on init.
  Future<void> drain(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('cloud mark matches the resolved row font on desktop', (
    tester,
  ) async {
    useProvider(_FakeSync(GameSyncStatus.upToDate));
    await pumpList(tester, designSize: const Size(640, 480));
    final title = tester.element(find.text('A Link to the Past'));
    final fontSize = DefaultTextStyle.of(title).style.fontSize!;
    expect(
      tester
          .widget<Icon>(find.byIcon(Symbols.check_circle_outline_rounded))
          .size,
      fontSize,
    );
    await drain(tester);
  });

  testWidgets('the mark is on the selected row and nowhere else', (
    tester,
  ) async {
    useProvider(_FakeSync(GameSyncStatus.upToDate));
    await pumpList(tester, selectedIndex: 1);

    final mark = find.byIcon(Symbols.check_circle_outline_rounded);
    expect(
      mark,
      findsOneWidget,
      reason: 'one mark for the one game it reports on',
    );

    // And it is on that row: the list is three rows of the same shape, so the
    // mark is placed by which title shares its line.
    final selected = tester.getRect(find.text('A Link to the Past'));
    expect(
      tester.getRect(mark).center.dy,
      moreOrLessEquals(selected.center.dy, epsilon: 4),
    );

    // At the end of the title, not before it.
    expect(tester.getRect(mark).left, greaterThan(selected.left));

    await drain(tester);
  });

  testWidgets('the mark leads the row\'s other marks', (tester) async {
    // It is the only one of the three that changes while you look at it — it
    // spins as a save uploads and settles when it lands — and the only one that
    // comes and goes with the cursor. Behind the others it would push them
    // sideways every time the selection moved.
    //
    // Pinned structurally rather than by geometry: the collection diamond and
    // the achievements trophy each need state this harness has no seam for (a
    // membership, and the config flag that turns the trophy on), so what is
    // asserted is the slot — the mark sits immediately after the title, and
    // anything else the row draws is appended behind it.
    useProvider(_FakeSync(GameSyncStatus.upToDate));
    await pumpList(tester, selectedIndex: 1);

    final row = tester
        .widgetList<Row>(
          find.descendant(
            of: find
                .ancestor(
                  of: find.text('A Link to the Past'),
                  matching: find.byType(GestureDetector),
                )
                .first,
            matching: find.byType(Row),
          ),
        )
        .first;

    final titleSlot = row.children.indexWhere((w) => w is Expanded);
    final markSlot = row.children.indexWhere((w) => w is NeoSyncStatusIcon);

    expect(titleSlot, isNonNegative, reason: 'the title takes the row');
    expect(
      markSlot,
      titleSlot + 1,
      reason: 'first of the marks at the end of the title',
    );

    // And it is drawn past the title, not before it.
    expect(
      tester.getRect(find.byIcon(Symbols.check_circle_outline_rounded)).left,
      greaterThan(tester.getRect(find.text('A Link to the Past')).left),
    );

    await drain(tester);
  });

  testWidgets('the mark follows the selection', (tester) async {
    useProvider(_FakeSync(GameSyncStatus.upToDate));
    await pumpList(tester, selectedIndex: 0);
    final first = tester.getRect(
      find.byIcon(Symbols.check_circle_outline_rounded),
    );

    await pumpList(tester, selectedIndex: 2);
    final third = tester.getRect(
      find.byIcon(Symbols.check_circle_outline_rounded),
    );

    expect(
      third.center.dy,
      greaterThan(first.center.dy),
      reason: 'it moved down the list with the cursor, not stayed put',
    );

    await drain(tester);
  });

  testWidgets('it reports the state, not just presence', (tester) async {
    // The mark is the reason the details card can stop carrying one: a glyph
    // that only ever said "cloud" would be decoration.
    useProvider(_FakeSync(GameSyncStatus.localOnly));
    await pumpList(tester);

    expect(find.byIcon(Symbols.cloud_upload_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.check_circle_outline_rounded), findsNothing);

    await drain(tester);
  });

  testWidgets('a system that does not sync gets no mark', (tester) async {
    // The widget answers this itself, but the row has to let it: the guard is
    // "is anything signed in", not "is this system synced", so a list that
    // pushed the second question into the row would drift out of step with it.
    useProvider(_FakeSync(GameSyncStatus.upToDate));
    await pumpList(tester, system: _system(sync: false));

    expect(find.byIcon(Symbols.check_circle_outline_rounded), findsNothing);

    await drain(tester);
  });

  testWidgets('signed out, no row carries a mark', (tester) async {
    useProvider(null);
    await pumpList(tester);

    expect(find.byIcon(Symbols.check_circle_outline_rounded), findsNothing);
    expect(find.byIcon(Symbols.cloud_off_rounded), findsNothing);

    await drain(tester);
  });
}
