import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/utils/gamepad_translator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'gamepad_test_clock.dart';

/// NEO-280: the Systems tab's header shows Search with the X glyph, but Search
/// was bound only to the West face button. On the AYN built-in controller
/// (Thor, Odin) West is the button printed Y, so the button printed X did
/// nothing and Y opened Search. The games grid and carousel views had the
/// same binding, while the games list already searches on X (#712).
///
/// Search now also opens on the input reported as X, keeping West: on an
/// Xbox-layout pad X is West and opens it once; on the AYN pad both X and Y
/// do.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('xyz.luan/gamepads');
  var vendorId = '2020';

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    // SoLoud has no native library in the test host.
    SfxService().setEnabled(false);
  });

  setUp(() {
    resetGamepadClock();
    GamepadEventTranslator.debugOperatingSystem = 'android';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'listGamepads') return null;
          return <dynamic>[
            {
              'id': '10',
              'name': 'pad',
              'systemInfo': {'vendorId': vendorId, 'productId': '0111'},
            },
          ];
        });
  });

  tearDown(() {
    restoreGamepadClock();
    GamepadEventTranslator.debugOperatingSystem = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// A key edge as the Android plugin sends it: press 0.0, release 1.0.
  Future<void> key(String keycode, {required bool down}) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(
            MethodCall('onGamepadEvent', {
              'gamepadId': '10',
              'time': 0,
              'type': 'button',
              'key': keycode,
              'value': down ? 0.0 : 1.0,
            }),
          ),
          (_) {},
        );
    await pumpEventQueue();
  }

  Future<void> press(String keycode) async {
    await key(keycode, down: true);
    await key(keycode, down: false);
    // Past the pacing between presses.
    advanceGamepadClock(const Duration(milliseconds: 300));
  }

  /// A navigator bound as the Systems tab and the games grid and carousel
  /// now bind Search: West and the input reported as X.
  Future<({GamepadNavigation nav, List<String> calls})> searchNav() async {
    final calls = <String>[];
    final nav = GamepadNavigation(
      onXButton: () => calls.add('search'),
      onWestButton: () => calls.add('search'),
      onFavorite: () => calls.add('favourite'),
    );
    addTearDown(nav.dispose);
    nav.initialize();
    await pumpEventQueue();
    nav.activate();
    // GamepadNavigation ignores input for 150 ms after it is activated.
    advanceGamepadClock(const Duration(milliseconds: 200));
    return (nav: nav, calls: calls);
  }

  // What the fix relies on: a navigator bound to X and West, as the views now
  // are, fires once per press on either layout.
  group('a navigator with Search on X and on West', () {
    test('AYN pad: the button printed X fires it once', () async {
      vendorId = '2020';
      final (nav: _, :calls) = await searchNav();

      await press('KEYCODE_BUTTON_X');

      expect(calls, ['search']);
    });

    test('AYN pad: the button printed Y (West) fires it once', () async {
      vendorId = '2020';
      final (nav: _, :calls) = await searchNav();

      await press('KEYCODE_BUTTON_Y');

      expect(calls, ['search']);
    });

    test('Xbox pad: X (West) fires it once, not twice; Y keeps its own '
        'action', () async {
      vendorId = '045e';
      final (nav: _, :calls) = await searchNav();

      await press('KEYCODE_BUTTON_X');
      await press('KEYCODE_BUTTON_Y');

      expect(calls, ['search', 'favourite']);
    });
  });

  group('wiring', () {
    String source(String path) => File(path).readAsStringSync();

    test('the Systems tab\'s carousel and grid open Search on X too', () {
      final systems = source(
        'lib/screens/systems_screen/my_systems_section/my_systems_grid.dart',
      );
      expect(
        'onXPressed: () => _openSearch(context)'.allMatches(systems),
        hasLength(2),
      );
      expect(
        'onWestPressed: () => _openSearch(context)'.allMatches(systems),
        hasLength(2),
      );
    });

    test('the games grid and carousel open Search on X too', () {
      for (final path in [
        'lib/screens/game_screen/my_games_grid.dart',
        'lib/screens/game_screen/my_games_carousel.dart',
      ]) {
        final view = source(path);
        expect(view, contains('onXButton: widget.onSearch'), reason: path);
        expect(view, contains('onWestButton: widget.onSearch'), reason: path);
      }
    });

    test('with no systems yet, X on the Systems tab opens Search', () {
      final app = source('lib/screens/app_screen.dart');
      final start = app.indexOf('void _handleXButton()');
      expect(start, isNot(-1), reason: '_handleXButton not found');
      final handler = app.substring(start, app.indexOf('\n  }\n', start));
      expect(handler, contains('AppTabs.systems'));
      expect(handler, contains('_openSearchFromHeader()'));
    });
  });
}
