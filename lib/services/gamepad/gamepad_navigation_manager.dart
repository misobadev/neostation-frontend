import 'package:neostation/services/logger_service.dart';

/// Represents a single layer in the navigation stack for gamepad focus management.
class NavLayer {
  final String id;
  final void Function() onActivate;
  final void Function() onDeactivate;

  /// Whether this layer belongs to a modal surface that must keep input focus
  /// until it is dismissed. See [GamepadNavigationManager.pushLayer].
  final bool modal;

  NavLayer({
    required this.id,
    required this.onActivate,
    required this.onDeactivate,
    this.modal = false,
  });
}

/// Global manager for gamepad/keyboard navigation focus across the application.
///
/// Maintains a focus stack to ensure that only the topmost UI layer receives
/// input events, preventing "ghost" navigation in background screens.
class GamepadNavigationManager {
  static final _log = LoggerService.instance;
  static final List<NavLayer> _stack = [];

  /// Number of registered layers. Exposed for tests and diagnostics: screens
  /// that fold several focus zones into one layer (the RetroAchievements
  /// sub-tab shell) assert that moving between zones never grows the stack.
  static int get stackDepth => _stack.length;

  /// Pushes a new navigation layer to the top of the stack and activates it.
  ///
  /// Automatically deactivates the previously active layer.
  ///
  /// Set [modal] for layers owned by a modal surface (dialogs). A modal layer
  /// cannot be displaced by a later non-modal push: background widgets that
  /// mount while the dialog is open are inserted *beneath* it instead, keeping
  /// their registration without taking input focus. Without this, a widget that
  /// appears late — e.g. the systems grid mounting when the startup ROM scan
  /// finishes behind the systems-update dialog — pushed itself on top and stole
  /// the controller, so A opened a system behind the dialog.
  ///
  /// CAVEAT: anything a modal opens *on top of itself* (a dropdown, an option
  /// picker) must be pushed with [modal] too, or it lands underneath its own
  /// parent and never receives input. Only mark self-contained dialogs modal.
  /// Set [background] when the pushing widget lives on a route that is not the
  /// current one. Such a layer registers *beneath* the active top layer instead
  /// of taking the controller, so it is ready when its route comes back but
  /// cannot steal input from the route in front of it.
  ///
  /// This matters because a backgrounded screen can re-mount a navigator
  /// without the user touching it: any provider change it listens to will
  /// rebuild it while it sits behind a pushed route. The systems screen doing
  /// exactly that — swapping its grid for its carousel when the shared
  /// `systemViewMode` changed — pushed its layer last and took the controller
  /// out from under the collections browser in front of it, so the D-pad drove
  /// the invisible screen behind (visible only as the second display's logos
  /// changing). [popLayersAbove] exists to repair the same situation after the
  /// fact for dialogs; this prevents it instead.
  static void pushLayer(
    String id, {
    required void Function() onActivate,
    required void Function() onDeactivate,
    bool modal = false,
    bool background = false,
  }) {
    _log.i(
      '[GamepadNavigationManager] Pushing layer: $id '
      '(modal: $modal, background: $background)',
    );

    // A background layer never takes focus from the route in front of it. With
    // an empty stack there is nothing in front, so it is the active layer by
    // default and falls through to the normal path — otherwise no layer would
    // hold the controller at all.
    if (background && !modal && _stack.isNotEmpty) {
      _log.i(
        '[GamepadNavigationManager] ${_stack.last.id} is in front; '
        'inserting $id beneath it',
      );
      _stack.insert(
        _stack.length - 1,
        NavLayer(
          id: id,
          onActivate: onActivate,
          onDeactivate: onDeactivate,
          modal: modal,
        ),
      );
      return;
    }

    // A non-modal layer never displaces an open modal. Slot it below the
    // lowest modal so the dialogs above it stay ordered, and so it becomes the
    // active layer once they are all dismissed.
    final firstModal = _stack.indexWhere((layer) => layer.modal);
    if (!modal && firstModal != -1) {
      _log.i(
        '[GamepadNavigationManager] Modal ${_stack[firstModal].id} holds focus; '
        'inserting $id beneath it',
      );
      _stack.insert(
        firstModal,
        NavLayer(
          id: id,
          onActivate: onActivate,
          onDeactivate: onDeactivate,
          modal: modal,
        ),
      );
      // Not activated: the modal above keeps focus. The new layer starts
      // inactive, which is the state a freshly built navigator is already in.
      return;
    }

    if (_stack.isNotEmpty) {
      _log.d(
        '[GamepadNavigationManager] Deactivating previous layer: ${_stack.last.id}',
      );
      try {
        _stack.last.onDeactivate();
      } catch (e) {
        _log.e('Error deactivating layer ${_stack.last.id}: $e');
      }
    }

    final newLayer = NavLayer(
      id: id,
      onActivate: onActivate,
      onDeactivate: onDeactivate,
      modal: modal,
    );
    _stack.add(newLayer);

    try {
      onActivate();
    } catch (e) {
      _log.e('Error activating layer $id: $e');
    }
  }

  /// Removes a navigation layer by its identifier and reactivates the new top layer.
  static void popLayer(String id) {
    if (_stack.isEmpty) return;

    _log.i('[GamepadNavigationManager] Popping layer: $id');

    final index = _stack.indexWhere((layer) => layer.id == id);
    if (index == -1) {
      _log.w('[GamepadNavigationManager] Layer $id not found in stack');
      return;
    }

    final isTop = index == _stack.length - 1;
    final layer = _stack.removeAt(index);

    if (isTop) {
      try {
        layer.onDeactivate();
      } catch (e) {
        _log.e('Error deactivating layer $id during pop: $e');
      }

      if (_stack.isNotEmpty) {
        _log.i(
          '[GamepadNavigationManager] Reactivating previous layer: ${_stack.last.id}',
        );
        try {
          _stack.last.onActivate();
        } catch (e) {
          _log.e('Error reactivating layer ${_stack.last.id}: $e');
        }
      }
    }
  }

  /// Deactivates all layers in the stack.
  ///
  /// Typically called when launching a game to prevent UI interaction during gameplay.
  static void deactivateAll() {
    if (_stack.isNotEmpty) {
      _log.i('[GamepadNavigationManager] Deactivating all layers');
      try {
        _stack.last.onDeactivate();
      } catch (e) {
        _log.e('Error deactivating top layer: $e');
      }
    }
  }

  /// Records which layer owned input when an external launch began.
  ///
  /// Cleared by [restoreFocusOwner].
  static String? _focusOwnerId;

  /// Remembers [id] as the layer to hand input back to when the game ends.
  ///
  /// Call it where the launch begins, before the emulator handoff — by the time
  /// the game exits, the stack may no longer say who was in charge.
  static void rememberFocusOwner(String id) {
    _focusOwnerId = id;
    _log.i('[GamepadNavigationManager] Launch focus owner: $id');
  }

  /// Returns input to the layer that owned it when the launch began.
  ///
  /// [reactivate] alone is not enough here. A launch tears down and rebuilds a
  /// lot of UI — the games list drops its entries to free memory for the
  /// emulator, artwork caches are cleared — and a background screen that
  /// remounts during that window re-pushes its own layer, landing it on top of
  /// the stack. Waking "the top layer" then wakes whatever drifted up there
  /// rather than the screen the user is looking at, and the controller appears
  /// dead: the observed case was the systems carousel re-registering behind the
  /// launch dialog, so returning from a game left input on the carousel while
  /// the games list stayed on screen and deactivated.
  ///
  /// Restoring the owner moves it back to the top, which is also the right
  /// order for what follows: a screen that mounted behind it stays behind it.
  /// Falls back to [reactivate] when nothing was remembered or the owner is
  /// gone (its screen was disposed while the game ran).
  static void restoreFocusOwner() {
    final ownerId = _focusOwnerId;
    _focusOwnerId = null;

    if (ownerId == null) {
      reactivate();
      return;
    }

    final index = _stack.indexWhere((layer) => layer.id == ownerId);
    if (index == -1) {
      _log.w(
        '[GamepadNavigationManager] Launch focus owner $ownerId is no longer '
        'registered; falling back to the top of the stack',
      );
      reactivate();
      return;
    }

    if (index != _stack.length - 1) {
      final displaced = _stack.last;
      _log.i(
        '[GamepadNavigationManager] Restoring $ownerId over ${displaced.id}, '
        'which took the top of the stack during the launch',
      );

      // The drifted layer may have been activated by its own push while the
      // game was running, so take input off it explicitly.
      try {
        displaced.onDeactivate();
      } catch (e) {
        _log.e('Error deactivating layer ${displaced.id}: $e');
      }

      _stack.add(_stack.removeAt(index));
    }

    reactivate();
  }

  /// Reactivates the topmost layer in the stack.
  static void reactivate() {
    if (_stack.isNotEmpty) {
      _log.i(
        '[GamepadNavigationManager] Reactivating top layer: ${_stack.last.id}',
      );
      try {
        _stack.last.onActivate();
      } catch (e) {
        _log.e('Error reactivating top layer: $e');
      }
    }
  }

  /// Removes every layer above [id] and reactivates [id].
  ///
  /// Used when a dialog must reclaim focus after an async action (e.g. changing
  /// a view mode) caused background widgets to push their own layers on top.
  static void popLayersAbove(String id) {
    final index = _stack.indexWhere((layer) => layer.id == id);
    if (index == -1) {
      _log.w(
        '[GamepadNavigationManager] Layer $id not found for popLayersAbove',
      );
      return;
    }

    while (_stack.length > index + 1) {
      final layer = _stack.removeLast();
      _log.i('[GamepadNavigationManager] popLayersAbove: removing ${layer.id}');
      try {
        layer.onDeactivate();
      } catch (e) {
        _log.e('Error deactivating layer ${layer.id}: $e');
      }
    }

    if (_stack.isNotEmpty) {
      _log.i(
        '[GamepadNavigationManager] popLayersAbove: reactivating ${_stack.last.id}',
      );
      try {
        _stack.last.onActivate();
      } catch (e) {
        _log.e('Error reactivating layer ${_stack.last.id}: $e');
      }
    }
  }
}
