import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/retro_achievements_dashboard_models.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/screens/retro_achievements_screen/ra_games_tab.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Direct-mount tests for the see-all Games sub-tab: rows, the identity
/// cursor, the chips zone, walls, and fetch orchestration. The shell-level
/// wiring — sub-tab switching, the A/tap drill-down against the local
/// library and RomM, REFRESH — lives in ra_sub_tab_shell_test.dart; these
/// tests pin the tab's own contract by driving [RaGamesTabState] the way
/// the shell's gamepad layer does.
///
/// The stub pins the provider's list state to plain fields so each test can
/// stage exactly one situation — a wall, a failed append, a filter — the
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

  testWidgets('rows render: title, console/date line, progress, awards', (
    tester,
  ) async {
    final provider = _TabProvider(
      items: [
        _game(0, kind: 'mastered'),
        _game(1, kind: 'completed'),
        _game(2),
      ],
      loaded: true,
    );
    final tabKey = GlobalKey<RaGamesTabState>();
    await _pumpTab(tester, provider, tabKey);

    expect(find.text('Game 0'), findsOneWidget);
    expect(find.text('Game 2'), findsOneWidget);
    expect(find.text('PlayStation • 2026-09-01'), findsNWidgets(3));
    // Progress text: earned/total, per row.
    expect(find.text('10/50'), findsOneWidget);
    expect(find.text('11/50'), findsOneWidget);
    expect(find.text('12/50'), findsOneWidget);
    // Only the awarded rows carry a badge.
    expect(find.text('Mastery'), findsOneWidget);
    expect(find.text('Completion'), findsOneWidget);
    // The chips row is part of the tab, All selected first.
    expect(find.text('All'), findsOneWidget);
    expect(find.text('Mastered'), findsOneWidget);
    expect(find.text('Beaten'), findsOneWidget);
    // More pages exist, so the end-of-list label must not.
    expect(find.text(raGamesEndOfListText), findsNothing);
    // The first row holds the cursor.
    expect(_selectedRows(), findsOneWidget);

    await _disposeTab(tester);
  });

  testWidgets('the cursor walks rows and A activates the row under it', (
    tester,
  ) async {
    final provider = _TabProvider(items: List.generate(6, _game), loaded: true);
    final tabKey = GlobalKey<RaGamesTabState>();
    final activated = <RaGamesListItem>[];
    await _pumpTab(tester, provider, tabKey, activated: activated);

    final state = tabKey.currentState!;
    expect(state.handleNavigateDown(), isTrue);
    expect(state.handleNavigateDown(), isTrue);
    state.activateCurrent();
    expect(activated.single.title, 'Game 2');

    await _disposeTab(tester);
  });

  testWidgets(
    'the identity cursor follows its game when a page re-sorts the list',
    (tester) async {
      final provider = _TabProvider(
        items: [_game(0), _game(1), _game(2)],
        loaded: true,
      );
      final tabKey = GlobalKey<RaGamesTabState>();
      final activated = <RaGamesListItem>[];
      await _pumpTab(tester, provider, tabKey, activated: activated);

      final state = tabKey.currentState!;
      state.handleNavigateDown();
      state.handleNavigateDown();
      state.activateCurrent();
      expect(activated.single.gameId, 202);

      // A later completion page lands a fresher game above the cursor's row.
      // An index cursor would have shifted onto Game 1; the identity cursor
      // stays on the game the player selected.
      provider.items = [
        _game(9, lastPlayed: DateTime(2026, 9, 18)),
        _game(0),
        _game(1),
        _game(2),
      ];
      await tester.pump();
      state.activateCurrent();
      expect(activated.last.gameId, 202);
      expect(activated.last.title, 'Game 2');

      await _disposeTab(tester);
    },
  );

  testWidgets('Up from row 0 arms the chips; Up again hands up to the strip', (
    tester,
  ) async {
    final provider = _TabProvider(items: List.generate(3, _game), loaded: true);
    final tabKey = GlobalKey<RaGamesTabState>();
    await _pumpTab(tester, provider, tabKey);

    final state = tabKey.currentState!;
    // Walking up from row 0 is the chips, not the strip.
    expect(state.handleNavigateUp(), isTrue);
    // Armed chips are the tab's top: false is the shell's park-on-strip
    // signal.
    expect(state.handleNavigateUp(), isFalse);
    // And Down walks back into the list at the parked cursor — the row
    // selection is where it was.
    expect(state.handleNavigateDown(), isTrue);
    state.activateCurrent();
    expect(find.text('Game 0'), findsOneWidget);

    await _disposeTab(tester);
  });

  testWidgets('Left/Right on the chips switch the filter without a refetch', (
    tester,
  ) async {
    final provider = _TabProvider(
      items: [
        _game(0),
        _game(1, kind: 'mastered'),
        _game(2, kind: 'completed'),
      ],
      loaded: true,
    );
    final tabKey = GlobalKey<RaGamesTabState>();
    final activated = <RaGamesListItem>[];
    await _pumpTab(tester, provider, tabKey, activated: activated);

    final state = tabKey.currentState!;
    state.handleNavigateUp(); // arm the chips

    // Left from All wraps to Beaten.
    expect(state.handleNavigateLeft(), isTrue);
    expect(provider.gamesFilter, RaGamesFilter.beaten);
    await tester.pump();
    expect(find.text('Game 2'), findsOneWidget);
    expect(find.text('Game 0'), findsNothing);
    // The switch is a client-side re-derivation: no fetch, ever.
    expect(provider.fetchLog, isEmpty);

    // Left again steps to Mastered; Right mirrors back.
    expect(state.handleNavigateLeft(), isTrue);
    expect(provider.gamesFilter, RaGamesFilter.mastered);
    await tester.pump();
    expect(find.text('Game 1'), findsOneWidget);
    expect(state.handleNavigateRight(), isTrue);
    expect(provider.gamesFilter, RaGamesFilter.beaten);
    await tester.pump();

    // Left/Right on the rows themselves are silent.
    state.handleNavigateDown(); // back into the list
    expect(state.handleNavigateLeft(), isFalse);
    expect(state.handleNavigateRight(), isFalse);
    expect(provider.fetchLog, isEmpty);

    await _disposeTab(tester);
  });

  testWidgets('A on the armed chips enters the list; A on a row activates', (
    tester,
  ) async {
    final provider = _TabProvider(items: List.generate(3, _game), loaded: true);
    final tabKey = GlobalKey<RaGamesTabState>();
    final activated = <RaGamesListItem>[];
    await _pumpTab(tester, provider, tabKey, activated: activated);

    final state = tabKey.currentState!;
    state.handleNavigateUp(); // arm the chips
    state.selectCurrent(); // A: into the list, activating nothing
    expect(activated, isEmpty);

    state.selectCurrent();
    expect(activated.single.title, 'Game 0');

    await _disposeTab(tester);
  });

  testWidgets('a filter that still shows the cursor keeps it on its game', (
    tester,
  ) async {
    final provider = _TabProvider(
      items: [
        _game(0),
        _game(1, kind: 'mastered'),
        _game(2, kind: 'mastered'),
      ],
      loaded: true,
    );
    final tabKey = GlobalKey<RaGamesTabState>();
    final activated = <RaGamesListItem>[];
    await _pumpTab(tester, provider, tabKey, activated: activated);

    final state = tabKey.currentState!;
    state.handleNavigateDown(); // Game 1, mastered

    // Switch to Mastered through the chips, the way the D-pad does: Up from
    // Game 1 walks to Game 0 first, the second Up arms the chips.
    state.handleNavigateUp();
    expect(state.handleNavigateUp(), isTrue); // chips armed
    expect(state.handleNavigateRight(), isTrue); // All → Mastered
    expect(provider.gamesFilter, RaGamesFilter.mastered);
    await tester.pump();

    // Still visible under the filter: the cursor stayed on its game.
    state.activateCurrent();
    expect(activated.single.gameId, 201);

    // Beaten includes mastered games, so the same row remains available under
    // the broader filter.
    expect(state.handleNavigateRight(), isTrue); // Mastered → Beaten
    await tester.pump();
    expect(find.text('Game 1'), findsOneWidget);
    state.activateCurrent();
    expect(activated.length, 2);

    await _disposeTab(tester);
  });

  testWidgets('walking near the end prefetches the next page as an append', (
    tester,
  ) async {
    // 12 rows with a load-more margin of 8: the prefetch fires once the
    // cursor reaches index 4.
    final provider = _TabProvider(
      items: List.generate(12, _game),
      loaded: true,
    );
    final tabKey = GlobalKey<RaGamesTabState>();
    await _pumpTab(tester, provider, tabKey);

    final state = tabKey.currentState!;
    for (var i = 0; i < 4; i++) {
      state.handleNavigateDown();
    }
    // An append, never a reset: the loaded rows stay under the cursor.
    expect(provider.fetchLog, ['games-page']);

    await _disposeTab(tester);
  });

  testWidgets('Down at the wall of loaded rows asks for the next page', (
    tester,
  ) async {
    final provider = _TabProvider(
      items: List.generate(12, _game),
      loaded: true,
    );
    final tabKey = GlobalKey<RaGamesTabState>();
    await _pumpTab(tester, provider, tabKey);

    // Park the cursor on the last row by tap: taps place the cursor without
    // prefetching, so the only thing that can ask for a page here is the
    // wall press itself.
    await tester.tap(find.text('Game 11'));
    await tester.pump();
    expect(provider.fetchLog, isEmpty);

    // The wall press is answered — another page is on its way — so it rings.
    expect(tabKey.currentState!.handleNavigateDown(), isTrue);
    expect(provider.fetchLog, ['games-page']);

    await _disposeTab(tester);
  });

  testWidgets('Down at the true end of the data is a silent boundary', (
    tester,
  ) async {
    final provider = _TabProvider(
      items: List.generate(3, _game),
      loaded: true,
      hasMore: false,
    );
    final tabKey = GlobalKey<RaGamesTabState>();
    await _pumpTab(tester, provider, tabKey);

    final state = tabKey.currentState!;
    // Up from row 0 arms the chips (the tab's own zone), not the strip.
    expect(state.handleNavigateUp(), isTrue);
    expect(state.handleNavigateUp(), isFalse);
    state.handleNavigateDown(); // back to the list
    state.handleNavigateDown();
    state.handleNavigateDown();
    expect(state.handleNavigateDown(), isFalse);
    expect(provider.fetchLog, isEmpty);
    // The end-of-list footer is the honest answer at the wall.
    expect(find.text(raGamesEndOfListText), findsOneWidget);

    await _disposeTab(tester);
  });

  testWidgets('tapping a row moves the cursor there and activates it', (
    tester,
  ) async {
    final provider = _TabProvider(items: List.generate(6, _game), loaded: true);
    final tabKey = GlobalKey<RaGamesTabState>();
    final activated = <RaGamesListItem>[];
    await _pumpTab(tester, provider, tabKey, activated: activated);

    await tester.tap(find.text('Game 3'));
    await tester.pump();
    expect(activated.single.title, 'Game 3');

    // The cursor followed the tap.
    tabKey.currentState!.activateCurrent();
    expect(activated.last.title, 'Game 3');
    expect(activated.length, 2);

    await _disposeTab(tester);
  });

  testWidgets('an empty, loaded list says so per filter', (tester) async {
    final provider = _TabProvider(items: const [], loaded: true);
    final tabKey = GlobalKey<RaGamesTabState>();
    await _pumpTab(tester, provider, tabKey);

    expect(find.text('No game activity yet'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // The empty copy follows the filter, because "none" means something
    // different per chip.
    provider.setGamesFilter(RaGamesFilter.mastered);
    await tester.pump();
    expect(find.text('No masteries yet'), findsOneWidget);

    await _disposeTab(tester);
  });

  testWidgets('a failed first page shows its error and Retry resets', (
    tester,
  ) async {
    final provider = _TabProvider(
      items: const [],
      error: 'Error loading games: Boom',
    );
    final tabKey = GlobalKey<RaGamesTabState>();
    await _pumpTab(tester, provider, tabKey);

    expect(find.text('Error loading games: Boom'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(provider.fetchLog, ['games-page-reset']);

    await _disposeTab(tester);
  });

  testWidgets('while a next page is in flight the footer spins', (
    tester,
  ) async {
    final provider = _TabProvider(
      items: List.generate(3, _game),
      loaded: true,
      loading: true,
    );
    final tabKey = GlobalKey<RaGamesTabState>();
    await _pumpTab(tester, provider, tabKey);

    expect(find.text('Game 1'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await _disposeTab(tester);
  });

  testWidgets('a failed append keeps the loaded rows and offers a retry', (
    tester,
  ) async {
    final provider = _TabProvider(
      items: List.generate(3, _game),
      loaded: true,
      error: 'Error loading games: Boom',
    );
    final tabKey = GlobalKey<RaGamesTabState>();
    await _pumpTab(tester, provider, tabKey);

    // Rows stay on screen; the error lives in the footer, not over the rows.
    expect(find.text('Game 1'), findsOneWidget);
    expect(find.text('Error loading games: Boom'), findsOneWidget);

    // The footer retry resumes the append rather than resetting the list.
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(provider.fetchLog, ['games-page']);

    await _disposeTab(tester);
  });

  testWidgets(
    'an activated tab fetches after the dwell; a parked one never does',
    (tester) async {
      final provider = _TabProvider(items: List.generate(3, _game));
      final tabKey = GlobalKey<RaGamesTabState>();
      await _pumpTab(tester, provider, tabKey, active: false);

      // Parked: no dwell fires no fetch, however long it stays parked.
      await tester.pump(const Duration(seconds: 1));
      expect(provider.fetchLog, isEmpty);

      // Becoming the shown sub-tab schedules the fetch.
      await _pumpTab(tester, provider, tabKey, active: true);
      await tester.pump(const Duration(milliseconds: 400));
      expect(provider.fetchLog, ['games-page-reset']);

      await _disposeTab(tester);
    },
  );

  testWidgets('a fresh list costs nothing to re-enter; a stale one re-reads', (
    tester,
  ) async {
    final provider = _TabProvider(items: List.generate(3, _game));
    final tabKey = GlobalKey<RaGamesTabState>();
    await _pumpTab(tester, provider, tabKey, active: true);
    await tester.pump(const Duration(milliseconds: 400));
    expect(provider.fetchLog, ['games-page-reset']);

    // Park and come back: fresh inside the staleness window, so the
    // re-entry fetch is a no-op.
    await _pumpTab(tester, provider, tabKey, active: false);
    await _pumpTab(tester, provider, tabKey, active: true);
    await tester.pump(const Duration(milliseconds: 400));
    expect(provider.fetchLog, ['games-page-reset']);

    // Once the window has passed (staged: the real getter reads the wall
    // clock, which a fake test clock cannot age), the next entry re-reads
    // from page one.
    provider.stale = true;
    await _pumpTab(tester, provider, tabKey, active: false);
    await _pumpTab(tester, provider, tabKey, active: true);
    await tester.pump(const Duration(milliseconds: 400));
    expect(provider.fetchLog, ['games-page-reset', 'games-page-reset']);

    await _disposeTab(tester);
  });

  testWidgets('a reload that drops the cursor row clamps the cursor home', (
    tester,
  ) async {
    final provider = _TabProvider(items: List.generate(3, _game), loaded: true);
    final tabKey = GlobalKey<RaGamesTabState>();
    final activated = <RaGamesListItem>[];
    await _pumpTab(tester, provider, tabKey, activated: activated);

    final state = tabKey.currentState!;
    state.handleNavigateDown();
    state.handleNavigateDown();

    // The reload drops the row the cursor was on entirely.
    provider.items = [_game(0)];
    await tester.pump();
    state.activateCurrent();
    expect(activated.single.title, 'Game 0');

    await _disposeTab(tester);
  });
}

const String raGamesEndOfListText = "That's every game in your history";

Finder _selectedRows() => find.byWidgetPredicate(
  // The filter chips are also Semantics-selected, but they carry labels;
  // the rows are bare selections.
  (w) =>
      w is Semantics &&
      w.properties.selected == true &&
      w.properties.label == null,
);

/// Mounts the tab the way the shell's IndexedStack does, minus the shell: the
/// same providers the tab reads, the same design size, and a [GlobalKey] the
/// test drives the state through.
Future<void> _pumpTab(
  WidgetTester tester,
  RetroAchievementsProvider provider,
  GlobalKey<RaGamesTabState> tabKey, {
  bool active = true,
  List<RaGamesListItem>? activated,
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
            body: RaGamesTab(
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

/// One merged-row fixture per index. Award kinds are staged per test; the
/// date is fixed so the console/date line reads the same in every assertion.
RaGamesListItem _game(int i, {String kind = '', DateTime? lastPlayed}) =>
    RaGamesListItem(
      gameId: 200 + i,
      title: 'Game $i',
      consoleId: 12,
      consoleName: 'PlayStation',
      imageIcon: '',
      imageBoxArt: '',
      maxPossible: 50,
      numAwarded: 10 + i,
      numAwardedHardcore: 4,
      highestAwardKind: kind.isEmpty ? null : kind,
      lastPlayed: lastPlayed ?? DateTime(2026, 9, 1),
      mostRecentAwardedDate: null,
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

  List<RaGamesListItem> items;
  bool _loaded;
  final bool loading;
  final bool hasMore;

  /// Doubles as the provider's general-purpose error member, which is what
  /// the staged list error is here anyway.
  @override
  final String? error;
  final List<String> fetchLog = [];

  RaGamesFilter _filter = RaGamesFilter.all;

  /// Staged staleness: the real getter reads `DateTime.now()`, which fake
  /// test clocks cannot age, so tests pin this instead — the tab only needs
  /// "fresh" and "stale" as answers.
  bool stale = false;

  @override
  RaGamesFilter get gamesFilter => _filter;

  @override
  bool get gamesListIsStale => stale;

  @override
  List<RaGamesListItem> get gamesListItems => items;

  @override
  List<RaGamesListItem> get visibleGamesListItems {
    switch (_filter) {
      case RaGamesFilter.all:
        return items;
      case RaGamesFilter.mastered:
        return items.where((item) => item.isMastered).toList();
      case RaGamesFilter.beaten:
        return items.where((item) => item.isBeaten).toList();
    }
  }

  @override
  bool get gamesListLoaded => _loaded;

  @override
  bool get gamesListLoading => loading;

  @override
  bool get gamesListHasMore => hasMore;

  @override
  String? get gamesListError => error;

  @override
  void setGamesFilter(RaGamesFilter filter) {
    _filter = filter;
    // The real provider notifies; the tab's Consumer depends on it when a
    // test stages the filter from outside the chips.
    notifyListeners();
  }

  @override
  Future<bool> loadGamesPage({bool reset = false}) async {
    fetchLog.add('games-page${reset ? '-reset' : ''}');
    markGamesListAttempted();
    _loaded = true;
    return true;
  }
}
