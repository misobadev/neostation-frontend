import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/config_model.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/screens/game_screen/game_options_dialog.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/widgets/context_menu/game_context_menu.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

/// The games Options panel is the Start-button replacement for the old Y
/// menu: game actions first, view actions below, with Add to and View Mode
/// opening their own lists.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    SfxService().setEnabled(false);
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
  });

  final targets = <GameContextMenuTarget>[
    GameContextMenuTarget(
      id: 'favorites',
      label: 'Favourites',
      icon: Symbols.favorite_rounded,
      isMember: false,
      setMember: (_) async => true,
    ),
    GameContextMenuTarget(
      id: 'collection:1',
      label: 'Co-op night',
      icon: Symbols.bookmark_rounded,
      isMember: true,
      setMember: (_) async => true,
    ),
  ];

  Widget host({
    bool canScrape = true,
    bool canIdentify = true,
    SqliteConfigProvider? config,
    ValueChanged<GameOptionsAction?>? onResult,
  }) {
    return ScreenUtilInit(
      designSize: const Size(1920, 1080),
      builder: (context, _) => ChangeNotifierProvider<SqliteConfigProvider>(
        create: (_) => config ?? _GridConfig(),
        child: MaterialApp(
          localizationsDelegates:
              FlutterLocalization.instance.localizationsDelegates,
          supportedLocales: FlutterLocalization.instance.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  final result = await showGameOptionsDialog(
                    context: context,
                    gameTitle: 'My Game',
                    targets: targets,
                    canScrape: canScrape,
                    canIdentify: canIdentify,
                    createTargetLabel: AppLocale.newCollection.getString(
                      context,
                    ),
                  );
                  onResult?.call(result);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openDialog(WidgetTester tester) async {
    await tester.pump();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('root lists the game and view actions', (tester) async {
    await tester.pumpWidget(host());
    await openDialog(tester);

    final context = tester.element(find.byType(GameOptionsDialog));

    expect(
      find.textContaining(
        AppLocale.gameOptionsThisGame.getString(context).toUpperCase(),
      ),
      findsOneWidget,
    );
    expect(
      find.text(AppLocale.gameSettings.getString(context)),
      findsOneWidget,
    );
    expect(find.text(AppLocale.hintScrape.getString(context)), findsOneWidget);
    expect(
      find.text(AppLocale.identifyGame.getString(context)),
      findsOneWidget,
    );
    expect(find.text(AppLocale.addTo.getString(context)), findsOneWidget);
    expect(
      find.text(AppLocale.systemOptionsGameSearch.getString(context)),
      findsOneWidget,
    );
    expect(find.text(AppLocale.viewMode.getString(context)), findsOneWidget);
    expect(find.text(AppLocale.randomGame.getString(context)), findsOneWidget);
  });

  testWidgets('games that cannot be scraped hide scrape and identify', (
    tester,
  ) async {
    await tester.pumpWidget(host(canScrape: false, canIdentify: false));
    await openDialog(tester);

    final context = tester.element(find.byType(GameOptionsDialog));

    expect(find.text(AppLocale.hintScrape.getString(context)), findsNothing);
    expect(find.text(AppLocale.identifyGame.getString(context)), findsNothing);
  });

  testWidgets('Add to opens the membership checklist', (tester) async {
    await tester.pumpWidget(host());
    await openDialog(tester);

    final context = tester.element(find.byType(GameOptionsDialog));
    await tester.tap(find.text(AppLocale.addTo.getString(context)));
    await tester.pumpAndSettle();

    expect(find.text('Favourites'), findsOneWidget);
    expect(find.text('Co-op night'), findsOneWidget);
    expect(
      find.text(AppLocale.newCollection.getString(context)),
      findsOneWidget,
    );
  });

  testWidgets('View Mode opens the view and card-size list', (tester) async {
    await tester.pumpWidget(host());
    await openDialog(tester);

    final context = tester.element(find.byType(GameOptionsDialog));
    await tester.tap(find.text(AppLocale.viewMode.getString(context)));
    await tester.pumpAndSettle();

    expect(
      find.text(AppLocale.viewModeGroup.getString(context)),
      findsOneWidget,
    );
    expect(find.text(AppLocale.listView.getString(context)), findsOneWidget);
    expect(find.text(AppLocale.gridView.getString(context)), findsOneWidget);
    expect(
      find.text(AppLocale.carouselView.getString(context)),
      findsOneWidget,
    );
    expect(
      find.text(AppLocale.cardSizeGroup.getString(context)),
      findsOneWidget,
    );
    for (final size in const ['S', 'M', 'L', 'XL']) {
      expect(find.text(size), findsOneWidget);
    }
  });

  testWidgets('remounting the game view keeps input in Options', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await openDialog(tester);
    final context = tester.element(find.byType(GameOptionsDialog));
    await tester.tap(find.text(AppLocale.viewMode.getString(context)));
    await tester.pumpAndSettle();

    // Switching view styles registers the replacement games navigator while
    // this dialog remains open. It must wait until the dialog is dismissed.
    var gamesActive = false;
    GamepadNavigationManager.pushLayer(
      'replacement_games_view',
      onActivate: () => gamesActive = true,
      onDeactivate: () => gamesActive = false,
    );
    try {
      expect(gamesActive, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(gamesActive, isTrue);
    } finally {
      GamepadNavigationManager.popLayer('replacement_games_view');
    }
  });

  for (final from in ['list', 'grid', 'carousel']) {
    for (final to in ['list', 'grid', 'carousel']) {
      if (from == to) continue;
      testWidgets('$from to $to keeps Back on Options', (tester) async {
        final viewNav = GamepadNavigation(onBack: () {});
        final db = DatabaseTestHelper();
        await db.setUp();
        final config = SqliteConfigProvider();
        await config.updateGameViewMode(from);
        config.addListener(() {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            GamepadNavigationManager.pushLayer(
              'switched_games_view',
              onActivate: viewNav.activate,
              onDeactivate: viewNav.deactivate,
            );
          });
        });
        try {
          await tester.pumpWidget(host(config: config));
          await openDialog(tester);
          final context = tester.element(find.byType(GameOptionsDialog));
          await tester.tap(find.text(AppLocale.viewMode.getString(context)));
          await tester.pumpAndSettle();
          final label = switch (to) {
            'list' => AppLocale.listView,
            'grid' => AppLocale.gridView,
            _ => AppLocale.carouselView,
          };
          await tester.tap(find.text(label.getString(context)));
          await tester.pumpAndSettle();
          expect(config.config.gameViewMode, to);
          expect(viewNav.isActive, isFalse);

          // Dispatch the active navigator's B action: first leave the submenu,
          // then dismiss Options. A hidden game view must not consume either.
          expect(GamepadNavigation.triggerBack(), isTrue);
          await tester.pumpAndSettle();
          expect(find.byType(GameOptionsDialog), findsOneWidget);
          expect(
            find.text(AppLocale.viewMode.getString(context)),
            findsOneWidget,
          );
          expect(GamepadNavigation.triggerBack(), isTrue);
          await tester.pumpAndSettle();
          expect(find.byType(GameOptionsDialog), findsNothing);
          expect(viewNav.isActive, isTrue);
        } finally {
          GamepadNavigationManager.popLayer('switched_games_view');
          viewNav.dispose();
          await tester.pumpWidget(const SizedBox.shrink());
          await db.tearDown();
        }
      });
    }
  }

  testWidgets('concurrent callers open only one Options menu', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();
    final open = tester
        .widget<ElevatedButton>(find.byType(ElevatedButton))
        .onPressed!;
    // Distinct input listeners can request the route before its first frame
    // registers modal focus. The shared entry point must reject the duplicate.
    open();
    open();
    await tester.pumpAndSettle();
    expect(find.byType(GameOptionsDialog, skipOffstage: false), findsOneWidget);
    expect(GamepadNavigation.triggerBack(), isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(GameOptionsDialog, skipOffstage: false), findsNothing);

    open();
    await tester.pumpAndSettle();
    expect(find.byType(GameOptionsDialog), findsOneWidget);
    expect(GamepadNavigation.triggerBack(), isTrue);
    await tester.pumpAndSettle();
  });

  testWidgets('Game Settings reports the action back to the host', (
    tester,
  ) async {
    GameOptionsAction? result;
    await tester.pumpWidget(host(onResult: (value) => result = value));
    await openDialog(tester);

    final context = tester.element(find.byType(GameOptionsDialog));
    await tester.tap(find.text(AppLocale.gameSettings.getString(context)));
    await tester.pumpAndSettle();

    expect(result, GameOptionsAction.settings);
  });
}

class _GridConfig extends SqliteConfigProvider {
  @override
  ConfigModel get config =>
      super.config.copyWith(gameViewMode: 'grid', gameGridColumns: 'M');
}
