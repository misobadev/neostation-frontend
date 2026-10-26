import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/main.dart' show NoFocusTraversalPolicy;
import 'package:neostation/models/romm_platform.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/screens/romm_screen/romm_browse_screen.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';
import 'fake_credential_backends.dart';

/// The browse screen's search row: what the controller can reach from it when
/// a search matches nothing, and what the line under the field reports.
///
/// A search that matches nothing must not strand the controller.
///
/// The ROM grid and list are the only widgets that own the ROM view's gamepad
/// layer and the only route back up to the search field, so a zero-result
/// search — which draws neither — leaves the browse screen's own layer on top
/// while a platform is open. Every direction then fell through to the platform
/// cursor, which is not on screen: the D-pad appeared dead, the stuck term
/// could not be cleared with the controller, and B backed out onto whichever
/// platform the invisible cursor had wandered to.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final dbHelper = DatabaseTestHelper();

  final snes = RommPlatform(id: 12, name: 'Super Nintendo', slug: 'snes');
  final megadrive = RommPlatform(id: 13, name: 'Mega Drive', slug: 'genesis');

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
  });

  setUp(() async {
    CredentialStore.debugUseBackends(
      secure: MemoryBackend(),
      file: MemoryBackend(),
    );
    await dbHelper.setUp();
    // No audio device in a test, and the sounds are fired unawaited.
    SfxService().setEnabled(false);
    // Static, so it survives between tests; a foreign owner makes the screen
    // start from the top rather than restoring another test's cursor.
    RommBrowseScreen.position.owner = 'unrelated';
  });

  tearDown(() async {
    RommService.debugUseHttpClient(null);
    CredentialStore.debugReset();
    await dbHelper.tearDown();
  });

  http.Response json(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: const {'content-type': 'application/json'},
  );

  /// A RomM with two platforms and a library in which nothing matches.
  void serveEmptyResults() {
    RommService.debugUseHttpClient(
      MockClient((request) async {
        switch (request.url.path) {
          case '/api/users/me':
            return json({'username': 'tester'});
          case '/api/platforms':
            return json([
              {
                'id': 12,
                'name': 'Super Nintendo',
                'slug': 'snes',
                'rom_count': 4,
              },
              {
                'id': 13,
                'name': 'Mega Drive',
                'slug': 'genesis',
                'rom_count': 4,
              },
            ]);
          case '/api/collections':
          case '/api/collections/virtual':
            return json([]);
          case '/api/roms':
            return json({'items': [], 'total': 0});
        }
        return http.Response('not found', 404);
      }),
    );
  }

  /// The same server, with its collections endpoint down. The browse screen
  /// asks for collections on every entry to the tab, so this is an ordinary
  /// failure to be sitting on — not one belonging to the search.
  void breakCollections() {
    RommService.debugUseHttpClient(
      MockClient((request) async {
        switch (request.url.path) {
          case '/api/users/me':
            return json({'username': 'tester'});
          case '/api/roms':
            return json({'items': [], 'total': 0});
          case '/api/collections':
          case '/api/collections/virtual':
            return http.Response('boom', 500);
        }
        return http.Response('not found', 404);
      }),
    );
  }

  /// A connected provider sitting in [platform] on a term that found nothing,
  /// which is the state the browse screen mishandled.
  Future<RommProvider> emptySearchIn(
    WidgetTester tester,
    RommPlatform platform,
  ) async {
    serveEmptyResults();
    final provider = RommProvider();
    addTearDown(provider.dispose);
    final error = await provider.connect(
      serverUrl: 'https://romm.local',
      apiKey: 'test-key',
    );
    expect(error, isNull, reason: 'the scripted server accepts the API key');
    await provider.loadPlatforms();
    expect(provider.platforms, hasLength(2));
    await provider.selectPlatform(platform, search: 'zzz');
    expect(provider.roms, isEmpty);
    return provider;
  }

  /// The setup reads the bundled system definitions and the database, which
  /// need the real clock rather than the widget tester's fake one.
  Future<RommProvider> connectedIn(
    WidgetTester tester,
    RommPlatform platform,
  ) async {
    late RommProvider provider;
    await tester.runAsync(() async {
      provider = await emptySearchIn(tester, platform);
    });
    return provider;
  }

  /// Lets the wall clock move on. The navigator throttles keys and ignores
  /// them for a moment after a layer activates, both measured with
  /// `DateTime.now()` — which the widget tester's fake clock does not advance.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 320)),
    );
    await tester.pump();
  }

  Future<void> pumpBrowser(WidgetTester tester, RommProvider provider) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1280, 720)),
        child: ScreenUtilInit(
          designSize: const Size(1280, 720),
          // The app disables Flutter's own focus traversal app-wide, so arrow
          // keys belong to the gamepad navigator rather than moving focus.
          // Without it here, an arrow key focuses the text field by traversal
          // and the test would pass for a reason the device never sees.
          builder: (context, child) => FocusTraversalGroup(
            policy: NoFocusTraversalPolicy(),
            child: MaterialApp(
              localizationsDelegates:
                  FlutterLocalization.instance.localizationsDelegates,
              supportedLocales: FlutterLocalization.instance.supportedLocales,
              theme: ThemeData(
                extensions: <ThemeExtension<dynamic>>[CornerRadii.m()],
              ),
              home: ChangeNotifierProvider<RommProvider>.value(
                value: provider,
                // The search field is the only focusable node in this subtree,
                // so the route's focus scope hands it the keyboard the moment
                // nothing else holds it — which the real app, full of other
                // chrome, never does. Left in, that focus alone would move the
                // cursor onto the search row (the field's focus listener does
                // exactly that), which is the thing under test. Excluded, the
                // row is reachable only the way a controller reaches it.
                child: const ExcludeFocus(child: RommBrowseScreen()),
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  /// One D-pad press, spaced past the navigator's key throttle.
  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await settle(tester);
  }

  String searchText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  for (final key in <LogicalKeyboardKey>[
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
  ]) {
    testWidgets('${key.keyLabel} reaches the search row, so the stuck term can '
        'still be cleared', (tester) async {
      final provider = await connectedIn(tester, snes);
      await pumpBrowser(tester, provider);
      expect(searchText(tester), 'zzz');

      // There is nothing else on screen to move within, so the direction takes
      // the cursor up to the search row; Right then walks it along to the
      // clear button, and A presses it.
      await press(tester, key);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.enter);

      expect(
        searchText(tester),
        isEmpty,
        reason: 'the term is reachable and clearable by D-pad alone',
      );
      expect(provider.searchTerm, isEmpty);
      expect(
        provider.currentPlatform,
        isNotNull,
        reason: 'and none of that left the platform',
      );
    });
  }

  testWidgets('a failing collections load is not reported under the search '
      'field', (tester) async {
    final provider = await connectedIn(tester, snes);
    await pumpBrowser(tester, provider);

    // Entering the tab again with the collections endpoint down: the browse
    // screen refetches both lists, and one of them fails.
    breakCollections();
    await tester.runAsync(() => provider.loadCollections(force: true));
    await settle(tester);

    expect(provider.lastError, isNotNull);
    expect(
      find.textContaining(provider.lastError!),
      findsNothing,
      reason:
          'the search caption reports the search, not the provider at large',
    );
  });

  /// The scripted server with every browse endpoint answering 500.
  void breakEverything() {
    RommService.debugUseHttpClient(
      MockClient((request) async {
        if (request.url.path == '/api/users/me') {
          return json({'username': 'tester'});
        }
        return http.Response('boom', 500);
      }),
    );
  }

  // What a browse failure reads as in English: the server's status, never the
  // client's own "Request failed (500)".
  final serverError = AppLocale.en[AppLocale.rommErrorServerStatus]
      .toString()
      .replaceFirst('{error}', '500');

  testWidgets('a failed search says why under the search field, in the app '
      'language', (tester) async {
    final provider = await connectedIn(tester, snes);
    await pumpBrowser(tester, provider);

    breakEverything();
    await tester.runAsync(() => provider.selectPlatform(snes, search: 'yyy'));
    await settle(tester);

    expect(provider.romsFailure, isNotNull);
    expect(find.text(serverError), findsOneWidget);
    expect(find.textContaining('Request failed'), findsNothing);
  });

  for (final view in [RommBrowseView.platforms, RommBrowseView.collections]) {
    testWidgets('a ${view.name} list that failed to load says why rather than '
        '"none found"', (tester) async {
      late RommProvider provider;
      await tester.runAsync(() async {
        serveEmptyResults();
        provider = RommProvider();
        await provider.connect(
          serverUrl: 'https://romm.local',
          apiKey: 'test-key',
        );
        // Nothing loaded yet, and the server now fails every list.
        breakEverything();
        await provider.loadPlatforms(force: true);
        await provider.loadCollections(force: true);
      });
      addTearDown(provider.dispose);
      expect(provider.platforms, isEmpty);
      expect(provider.collections, isEmpty);
      RommBrowseScreen.position
        ..owner = RommBrowsePosition.ownerOf(provider)
        ..view = view;
      await pumpBrowser(tester, provider);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await settle(tester);

      expect(find.text(serverError), findsOneWidget);
      expect(
        find.text(
          AppLocale
              .en[view == RommBrowseView.platforms
                  ? AppLocale.rommNoPlatforms
                  : AppLocale.rommNoCollections]
              .toString(),
        ),
        findsNothing,
      );
    });
  }

  testWidgets('directions leave the off-screen platform cursor where it was', (
    tester,
  ) async {
    // Drilled into the second platform, so a cursor that moves at all is
    // recorded somewhere else — and B would back out onto that instead.
    final provider = await connectedIn(tester, megadrive);
    // What drilling in from the list leaves behind: the cursor sits on the
    // platform that was opened, and the screen restores it on every entry.
    RommBrowseScreen.position
      ..owner = RommBrowsePosition.ownerOf(provider)
      ..view = RommBrowseView.platforms
      ..platformIndex = 1;
    await pumpBrowser(tester, provider);

    // An odd number of presses: each one used to walk the hidden platform
    // cursor, and an odd walk over two platforms does not land back on the
    // one it started from.
    for (var i = 0; i < 3; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }

    // Leaving the tab is what records the cursor for the next visit.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    expect(
      RommBrowseScreen.position.platformIndex,
      1,
      reason: 'the platform drilled into is still the one B backs out to',
    );
  });
}
