import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';

/// Records which layer the manager considers active, in push/activation order.
class _Recorder {
  final List<String> events = [];

  void push(String id, {bool modal = false, bool background = false}) {
    GamepadNavigationManager.pushLayer(
      id,
      onActivate: () => events.add('+$id'),
      onDeactivate: () => events.add('-$id'),
      modal: modal,
      background: background,
    );
  }

  void pop(String id) => GamepadNavigationManager.popLayer(id);
}

void main() {
  group('GamepadNavigationManager background layers', () {
    test('a backgrounded push does not take the controller', () {
      final r = _Recorder();
      r.push('collections_browser_grid#1');
      r.events.clear();

      // The systems screen sits behind the pushed collections route. A shared
      // setting change re-mounts its view, which re-registers its layer.
      r.push('my_systems_list', background: true);

      expect(r.events, isEmpty);

      r.pop('my_systems_list');
      r.pop('collections_browser_grid#1');
    });

    test('the backgrounded layer becomes active once the route above pops', () {
      final r = _Recorder();
      r.push('collections_browser_grid#1');
      r.push('my_systems_list', background: true);
      r.events.clear();

      r.pop('collections_browser_grid#1');

      expect(r.events, ['-collections_browser_grid#1', '+my_systems_list']);

      r.pop('my_systems_list');
    });

    test('with an empty stack a background push still activates', () {
      final r = _Recorder();
      r.push('my_systems_list', background: true);

      expect(r.events, ['+my_systems_list']);

      r.pop('my_systems_list');
    });

    test('switching the shared view mode keeps the front route in control', () {
      // The exact on-device sequence that broke: changing systemViewMode
      // disposes and re-mounts BOTH the collections browser in front and the
      // systems screen behind it, and the background screen pushed last.
      final r = _Recorder();
      r.push('my_systems_list', background: true);
      r.push('collections_browser_grid#1');
      r.events.clear();

      r.pop('my_systems_list');
      r.pop('collections_browser_grid#1');
      r.push('collections_browser_carousel#1');
      r.push('my_systems_carousel', background: true);

      // The collections carousel — the visible route — holds the controller.
      // Before the fix the systems carousel landed on top, so the D-pad drove
      // the invisible screen behind it.
      expect(r.events.last, '+collections_browser_carousel#1');

      r.events.clear();
      r.pop('collections_browser_carousel#1');
      expect(r.events, [
        '-collections_browser_carousel#1',
        '+my_systems_carousel',
      ]);

      r.pop('my_systems_carousel');
    });
  });

  group('GamepadNavigationManager modal layers', () {
    test('a non-modal push does not steal focus from an open modal', () {
      final r = _Recorder();
      r.push('app_screen');
      r.push('systems_update_dialog', modal: true);
      r.events.clear();

      // The systems grid mounts when the startup scan finishes, behind the
      // dialog. It must not take the controller.
      r.push('my_systems_list');

      expect(r.events, isEmpty);

      r.pop('my_systems_list');
      r.pop('systems_update_dialog');
      r.pop('app_screen');
    });

    test(
      'the layer pushed under a modal becomes active once it is dismissed',
      () {
        final r = _Recorder();
        r.push('app_screen');
        r.push('systems_update_dialog', modal: true);
        r.push('my_systems_list');
        r.events.clear();

        r.pop('systems_update_dialog');

        expect(r.events, ['-systems_update_dialog', '+my_systems_list']);

        r.pop('my_systems_list');
        r.pop('app_screen');
      },
    );

    test('a modal still stacks on top of another modal', () {
      final r = _Recorder();
      r.push('app_screen');
      r.push('update_dialog', modal: true);
      r.events.clear();

      r.push('systems_update_dialog', modal: true);

      expect(r.events, ['-update_dialog', '+systems_update_dialog']);

      r.pop('systems_update_dialog');
      r.pop('update_dialog');
      r.pop('app_screen');
    });

    test(
      'non-modal pushes slot below the lowest modal, keeping dialog order',
      () {
        final r = _Recorder();
        r.push('app_screen');
        r.push('update_dialog', modal: true);
        r.push('systems_update_dialog', modal: true);
        r.push('my_systems_list');
        r.events.clear();

        // Dismissing the top dialog must return focus to the one underneath it,
        // not to the background layer that mounted late.
        r.pop('systems_update_dialog');
        expect(r.events, ['-systems_update_dialog', '+update_dialog']);

        r.events.clear();
        r.pop('update_dialog');
        expect(r.events, ['-update_dialog', '+my_systems_list']);

        r.pop('my_systems_list');
        r.pop('app_screen');
      },
    );

    test('ordinary stacking is unchanged when no modal is open', () {
      final r = _Recorder();
      r.push('app_screen');
      r.events.clear();

      r.push('my_systems_list');
      expect(r.events, ['-app_screen', '+my_systems_list']);

      r.events.clear();
      r.pop('my_systems_list');
      expect(r.events, ['-my_systems_list', '+app_screen']);

      r.pop('app_screen');
    });
  });

  group('GamepadNavigationManager launch focus owner', () {
    test(
      'returns input to the launching screen, not to whatever drifted up',
      () {
        // The observed failure: launching frees memory and clears artwork
        // caches, the systems carousel remounts behind the launch dialog and
        // re-pushes its layer, and the games list the user is looking at ends up
        // buried. Waking "the top layer" then woke the carousel and the
        // controller looked dead.
        final r = _Recorder();
        r.push('app_screen');
        r.push('my_systems_list');
        r.push('system_games_list');

        GamepadNavigationManager.rememberFocusOwner('system_games_list');
        GamepadNavigationManager.deactivateAll();

        // The background screen remounts mid-launch and lands on top.
        r.pop('my_systems_list');
        r.push('my_systems_list');
        r.events.clear();

        GamepadNavigationManager.restoreFocusOwner();

        expect(r.events, ['-my_systems_list', '+system_games_list']);

        r.pop('system_games_list');
        r.pop('my_systems_list');
        r.pop('app_screen');
      },
    );

    test('leaves the owner alone when it is already on top', () {
      final r = _Recorder();
      r.push('app_screen');
      r.push('system_games_list');

      GamepadNavigationManager.rememberFocusOwner('system_games_list');
      GamepadNavigationManager.deactivateAll();
      r.events.clear();

      GamepadNavigationManager.restoreFocusOwner();

      expect(r.events, [
        '+system_games_list',
      ], reason: 'the ordinary path must not churn the stack');

      r.pop('system_games_list');
      r.pop('app_screen');
    });

    test('falls back to the top layer when the owner is gone', () {
      // Its screen was disposed while the game ran.
      final r = _Recorder();
      r.push('app_screen');
      r.push('system_games_list');

      GamepadNavigationManager.rememberFocusOwner('system_games_list');
      GamepadNavigationManager.deactivateAll();
      r.pop('system_games_list');
      r.events.clear();

      GamepadNavigationManager.restoreFocusOwner();

      expect(r.events, ['+app_screen']);

      r.pop('app_screen');
    });

    test('falls back to the top layer when no owner was remembered', () {
      final r = _Recorder();
      r.push('app_screen');
      r.push('my_systems_list');
      GamepadNavigationManager.deactivateAll();
      r.events.clear();

      GamepadNavigationManager.restoreFocusOwner();

      expect(r.events, ['+my_systems_list']);

      r.pop('my_systems_list');
      r.pop('app_screen');
    });

    test('a remembered owner is consumed, not reused by the next launch', () {
      final r = _Recorder();
      r.push('app_screen');
      r.push('system_games_list');

      GamepadNavigationManager.rememberFocusOwner('system_games_list');
      GamepadNavigationManager.restoreFocusOwner();

      // A later layer opens with nothing remembered for it. A stale owner
      // would drag input back to the games list underneath.
      r.push('game_settings_dialog');
      r.events.clear();

      GamepadNavigationManager.restoreFocusOwner();

      expect(r.events, ['+game_settings_dialog']);

      r.pop('game_settings_dialog');
      r.pop('system_games_list');
      r.pop('app_screen');
    });

    test('the modal launch dialog keeps input while a screen remounts', () {
      // The dialog owns A/B (dismiss) for its whole lifetime; a background
      // remount used to take that off it.
      final r = _Recorder();
      r.push('app_screen');
      r.push('system_games_list');
      r.push('game_launch_dialog', modal: true);
      r.events.clear();

      r.pop('my_systems_list'); // Not registered; mirrors a real remount.
      r.push('my_systems_list');

      expect(r.events, isEmpty);

      r.pop('game_launch_dialog');
      r.pop('my_systems_list');
      r.pop('system_games_list');
      r.pop('app_screen');
    });
  });

  group('GamepadNavigationManager duplicate routes', () {
    // Search's "Go to game" opens a games list over search, which may itself
    // sit over the same system's games list. Each copy registers its layer
    // under a per-instance id and pops it twice (on back, then in dispose).
    test('backing out of the top copy hands input to the bottom copy', () {
      final r = _Recorder();
      r.push('my_systems_list');
      r.push('system_games_list#1');
      r.push('search_screen');
      r.push('system_games_list#2');

      // The top list backs out: once from its back handler, once on dispose.
      r.pop('system_games_list#2');
      r.pop('system_games_list#2');
      r.events.clear();

      r.pop('search_screen');

      expect(r.events, ['-search_screen', '+system_games_list#1']);

      r.pop('system_games_list#1');
      r.pop('my_systems_list');
    });

    test('a shared id is what broke it', () {
      // Documents the failure the per-instance ids prevent: popLayer resolves
      // the first match, so the top copy unregistered the bottom one.
      final r = _Recorder();
      r.push('my_systems_list');
      r.push('system_games_list');
      r.push('search_screen');
      r.push('system_games_list');

      r.pop('system_games_list');
      r.pop('system_games_list');
      r.events.clear();

      r.pop('search_screen');

      expect(r.events, ['-search_screen', '+my_systems_list']);

      r.pop('my_systems_list');
    });
  });
}
