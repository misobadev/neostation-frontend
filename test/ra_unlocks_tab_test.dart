import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/retro_achievements_dashboard_models.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/screens/retro_achievements_screen/ra_unlocks_tab.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Direct-mount tests for the see-all Unlocks sub-tab: rows, cursor, walls,
/// and fetch orchestration. The shell-level wiring — sub-tab switching, the
/// A/tap drill-down against the local library and RomM, REFRESH — lives in
/// ra_sub_tab_shell_test.dart; these tests pin the tab's own contract by
/// driving [RaUnlocksTabState] the way the shell's gamepad layer does.
///
/// The stub pins the provider's list state to plain fields so each test can
/// stage exactly one situation — a wall, a failed append, a fresh page — the
/// way the dashboard hub tests stage theirs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // Taps play nav sounds through a native engine the test runner lacks.
    SfxService().setEnabled(false);
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });

  testWidgets('rows render: title, game line, hardcore chip, points', (
    tester,
  ) async {
    final provider = _TabProvider(
      items: [_unlock(0), _unlock(1, hardcore: false), _unlock(2)],
      loaded: true,
    );
    final tabKey = GlobalKey<RaUnlocksTabState>();
    await _pumpTab(tester, provider, tabKey);

    expect(find.text('Unlock 0'), findsOneWidget);
    expect(find.text('Unlock 2'), findsOneWidget);
    expect(find.text('Game 0 • NES'), findsOneWidget);
    // Only the two hardcore rows carry the chip.
    expect(find.text('Hardcore'), findsNWidgets(2));
    expect(find.text('5 pts'), findsNWidgets(3));
    // More pages exist, so the end-of-list label must not.
    expect(find.text(raUnlocksEndOfListText), findsNothing);
    // The first row holds the cursor.
    expect(_selectedRows(), findsOneWidget);

    await _disposeTab(tester);
  });

  testWidgets('the cursor walks rows and A activates the row under it', (
    tester,
  ) async {
    final provider = _TabProvider(
      items: List.generate(6, _unlock),
      loaded: true,
    );
    final tabKey = GlobalKey<RaUnlocksTabState>();
    final activated = <RetroAchievementRecentUnlockItem>[];
    await _pumpTab(tester, provider, tabKey, activated: activated);

    final state = tabKey.currentState!;
    expect(state.moveSelection(1), isTrue);
    expect(state.moveSelection(1), isTrue);
    state.activateCurrent();
    expect(activated.single.title, 'Unlock 2');

    await _disposeTab(tester);
  });

  testWidgets('walking near the end prefetches the next page as an append', (
    tester,
  ) async {
    // 12 rows with a load-more margin of 8: the prefetch fires once the
    // cursor reaches index 4.
    final provider = _TabProvider(
      items: List.generate(12, _unlock),
      loaded: true,
    );
    final tabKey = GlobalKey<RaUnlocksTabState>();
    await _pumpTab(tester, provider, tabKey);

    final state = tabKey.currentState!;
    for (var i = 0; i < 4; i++) {
      state.moveSelection(1);
    }
    // An append, never a reset: the loaded rows stay under the cursor.
    expect(provider.fetchLog, ['unlocks-page']);

    await _disposeTab(tester);
  });

  testWidgets('Down at the wall of loaded rows asks for the next page', (
    tester,
  ) async {
    final provider = _TabProvider(
      items: List.generate(12, _unlock),
      loaded: true,
    );
    final tabKey = GlobalKey<RaUnlocksTabState>();
    await _pumpTab(tester, provider, tabKey);

    // Park the cursor on the last row by tap: taps place the cursor without
    // prefetching, so the only thing that can ask for a page here is the
    // wall press itself.
    await tester.tap(find.text('Unlock 11'));
    await tester.pump();
    expect(provider.fetchLog, isEmpty);

    // The wall press is answered — another page is on its way — so it rings.
    expect(tabKey.currentState!.moveSelection(1), isTrue);
    expect(provider.fetchLog, ['unlocks-page']);

    await _disposeTab(tester);
  });

  testWidgets('Down at the true end of the data is a silent boundary', (
    tester,
  ) async {
    final provider = _TabProvider(
      items: List.generate(3, _unlock),
      loaded: true,
      hasMore: false,
    );
    final tabKey = GlobalKey<RaUnlocksTabState>();
    final activated = <RetroAchievementRecentUnlockItem>[];
    await _pumpTab(tester, provider, tabKey, activated: activated);

    final state = tabKey.currentState!;
    // Up at the first row parks on the strip (the shell's rule).
    expect(state.moveSelection(-1), isFalse);
    state.moveSelection(1);
    state.moveSelection(1);
    expect(state.moveSelection(1), isFalse);
    expect(provider.fetchLog, isEmpty);
    // The end-of-list footer is the honest answer at the wall.
    expect(find.text(raUnlocksEndOfListText), findsOneWidget);

    await _disposeTab(tester);
  });

  testWidgets('tapping a row moves the cursor there and activates it', (
    tester,
  ) async {
    final provider = _TabProvider(
      items: List.generate(6, _unlock),
      loaded: true,
    );
    final tabKey = GlobalKey<RaUnlocksTabState>();
    final activated = <RetroAchievementRecentUnlockItem>[];
    await _pumpTab(tester, provider, tabKey, activated: activated);

    await tester.tap(find.text('Unlock 3'));
    await tester.pump();
    expect(activated.single.title, 'Unlock 3');

    // The cursor followed the tap.
    tabKey.currentState!.activateCurrent();
    expect(activated.last.title, 'Unlock 3');
    expect(activated.length, 2);

    await _disposeTab(tester);
  });

  testWidgets('an empty, loaded list says so', (tester) async {
    final provider = _TabProvider(items: const [], loaded: true);
    final tabKey = GlobalKey<RaUnlocksTabState>();
    await _pumpTab(tester, provider, tabKey);

    expect(find.text('No recent unlocks in the last 30 days'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await _disposeTab(tester);
  });

  testWidgets('a failed first page shows its error and Retry resets', (
    tester,
  ) async {
    final provider = _TabProvider(
      items: const [],
      error: 'Error loading recent unlocks: Boom',
    );
    final tabKey = GlobalKey<RaUnlocksTabState>();
    await _pumpTab(tester, provider, tabKey);

    expect(find.text('Error loading recent unlocks: Boom'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(provider.fetchLog, ['unlocks-page-reset']);

    await _disposeTab(tester);
  });

  testWidgets('while a next page is in flight the footer spins', (
    tester,
  ) async {
    final provider = _TabProvider(
      items: List.generate(3, _unlock),
      loaded: true,
      loading: true,
    );
    final tabKey = GlobalKey<RaUnlocksTabState>();
    await _pumpTab(tester, provider, tabKey);

    expect(find.text('Unlock 1'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await _disposeTab(tester);
  });

  testWidgets('a failed append keeps the loaded rows and offers a retry', (
    tester,
  ) async {
    final provider = _TabProvider(
      items: List.generate(3, _unlock),
      loaded: true,
      error: 'Error loading recent unlocks: Boom',
    );
    final tabKey = GlobalKey<RaUnlocksTabState>();
    await _pumpTab(tester, provider, tabKey);

    // Rows stay on screen; the error lives in the footer, not over the rows.
    expect(find.text('Unlock 1'), findsOneWidget);
    expect(find.text('Error loading recent unlocks: Boom'), findsOneWidget);

    // The footer retry resumes the append rather than resetting the list.
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(provider.fetchLog, ['unlocks-page']);

    await _disposeTab(tester);
  });

  testWidgets(
    'an activated tab fetches after the dwell; a parked one never does',
    (tester) async {
      final provider = _TabProvider(items: List.generate(3, _unlock));
      final tabKey = GlobalKey<RaUnlocksTabState>();
      await _pumpTab(tester, provider, tabKey, active: false);

      // Parked: no dwell fires no fetch, however long it stays parked.
      await tester.pump(const Duration(seconds: 1));
      expect(provider.fetchLog, isEmpty);

      // Becoming the shown sub-tab schedules the fetch.
      await _pumpTab(tester, provider, tabKey, active: true);
      await tester.pump(const Duration(milliseconds: 400));
      expect(provider.fetchLog, ['unlocks-page-reset']);

      await _disposeTab(tester);
    },
  );

  testWidgets('a reload that shortens the list clamps the cursor home', (
    tester,
  ) async {
    final provider = _TabProvider(
      items: List.generate(3, _unlock),
      loaded: true,
    );
    final tabKey = GlobalKey<RaUnlocksTabState>();
    final activated = <RetroAchievementRecentUnlockItem>[];
    await _pumpTab(tester, provider, tabKey, activated: activated);

    final state = tabKey.currentState!;
    state.moveSelection(1);
    state.moveSelection(1);

    // The list shrinks under a cursor parked on its last row.
    provider.items = [_unlock(0)];
    await tester.pump();
    state.activateCurrent();
    expect(activated.single.title, 'Unlock 0');

    await _disposeTab(tester);
  });
}

const String raUnlocksEndOfListText =
    "That's every unlock from the last 30 days";

Finder _selectedRows() => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.selected == true,
);

/// Mounts the tab the way the shell's IndexedStack does, minus the shell: the
/// same providers the tab reads, the same design size, and a [GlobalKey] the
/// test drives the state through.
Future<void> _pumpTab(
  WidgetTester tester,
  RetroAchievementsProvider provider,
  GlobalKey<RaUnlocksTabState> tabKey, {
  bool active = true,
  List<RetroAchievementRecentUnlockItem>? activated,
}) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<RetroAchievementsProvider>.value(
          value: provider,
        ),
      ],
      child: ScreenUtilInit(
        designSize: const Size(1280, 720),
        builder: (context, _) => MaterialApp(
          localizationsDelegates:
              FlutterLocalization.instance.localizationsDelegates,
          supportedLocales: FlutterLocalization.instance.supportedLocales,
          home: Scaffold(
            body: RaUnlocksTab(
              key: tabKey,
              active: active,
              onActivate: activated == null ? (_) {} : activated.add,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// The tab's scroll controller schedules a 100ms initial-centering timer from
/// a post-frame callback (so the timer only *exists* on the frame after
/// mount), and it is an anonymous timer dispose cannot cancel: flush a frame
/// so the timer exists, then advance past it, before tearing the tree down.
Future<void> _disposeTab(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 150));
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

/// One unlock row fixture per index, matching the shell suite's numbering
/// (gameId 100 + i) so cross-file assertions read the same.
RetroAchievementRecentUnlockItem _unlock(int i, {bool hardcore = true}) =>
    RetroAchievementRecentUnlockItem(
      date: '2026-09-01 10:00:00',
      hardcoreMode: hardcore,
      achievementId: i,
      title: 'Unlock $i',
      description: '',
      badgeName: 'badge$i',
      badgeUrl: '',
      points: 5,
      trueRatio: 2,
      type: '',
      author: '',
      authorUlid: '',
      gameTitle: 'Game $i',
      gameIcon: '',
      gameId: 100 + i,
      consoleName: 'NES',
      gameUrl: '',
    );

class _TabProvider extends RetroAchievementsProvider {
  /// The loaded flag is the one mutable piece — the fetch path flips it the
  /// way the real provider's does. Everything else stays pinned per test.
  _TabProvider({
    this.items = const [],
    bool loaded = false,
    this.loading = false,
    this.hasMore = true,
    this.error,
  }) : _loaded = loaded;

  List<RetroAchievementRecentUnlockItem> items;
  bool _loaded;
  final bool loading;
  final bool hasMore;

  /// Doubles as the provider's general-purpose error member, which is what
  /// the staged list error is here anyway.
  @override
  final String? error;
  final List<String> fetchLog = [];

  @override
  List<RetroAchievementRecentUnlockItem> get unlocksListItems => items;

  @override
  bool get unlocksListLoaded => _loaded;

  @override
  bool get unlocksListLoading => loading;

  @override
  bool get unlocksListHasMore => hasMore;

  @override
  String? get unlocksListError => error;

  @override
  Future<bool> loadUnlocksPage({bool reset = false}) async {
    fetchLog.add('unlocks-page${reset ? '-reset' : ''}');
    markUnlocksListAttempted();
    _loaded = true;
    return true;
  }
}
