import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gamepads/gamepads.dart';
import 'package:window_manager/window_manager.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/sfx_service.dart';
import '../responsive.dart';
import 'desktop_window_focus.dart';
import 'gamepad_translator.dart';
import 'select_tap.dart';
import '../main.dart' show FullscreenNotifier;

/// Metadata for a connected gamepad device.
class GamepadInfo {
  final String id;
  final String name;

  /// Connection type identifier (e.g., "wired", "wireless", "bluetooth").
  final String? connectionType;

  /// Driver name reported by the system.
  final String? driver;

  /// Internal device path or system identifier.
  final String? devicePath;

  /// Raw hardware information (VID/PID).
  final Map<String, dynamic>? systemInfo;

  GamepadInfo({
    required this.id,
    required this.name,
    this.connectionType,
    this.driver,
    this.devicePath,
    this.systemInfo,
  });

  @override
  String toString() {
    final connection = connectionType != null ? ' [$connectionType]' : '';
    return '$id: $name$connection';
  }
}

/// Axis whose held-direction repeats escalate into alphabetical letter jumps.
///
/// This is the axis the *items* run along in a given view: vertical for the
/// list and grid, horizontal for the carousel.
enum LetterJumpAxis { vertical, horizontal }

/// Core service for managing gamepad and keyboard navigation within the application.
///
/// Handles input translation, debouncing, auto-repeat logic, and callback dispatching.
class GamepadNavigation {
  final Function? onNavigateUp;
  final Function? onNavigateDown;
  final Function? onNavigateLeft;
  final Function? onNavigateRight;
  final VoidCallback? onPreviousTab;
  final VoidCallback? onNextTab;
  final VoidCallback? onSelectItem;
  final VoidCallback? onBack;
  final VoidCallback? onFavorite;
  final VoidCallback? onSettings;
  final VoidCallback? onXButton;
  final VoidCallback? onLeftStickClick;
  final VoidCallback? onRightStickClick;
  final VoidCallback? onSelectButton;
  final VoidCallback? onLeftBumper;
  final VoidCallback? onRightBumper;

  /// Select (View) chord combos. On its own Select fires [onSelectButton], or
  /// [globalSelectTap] when the layer defines none.
  /// While it is held (or within a short window of a pulse),
  /// a face-button press fires the matching modifier callback instead of its
  /// normal action, and suppresses that normal action.
  final VoidCallback? onSelectModifierA;
  final VoidCallback? onSelectModifierB;
  final VoidCallback? onSelectModifierX;
  final VoidCallback? onSelectModifierY;

  /// ES-DE style alphabetical jumping. Once a direction on [letterJumpAxis] has
  /// been held for longer than `_letterJumpAfter`, each repeat calls this with
  /// `true` for forward (down / right) instead of moving one item, and then
  /// dwells on the new letter so the user can release in time. Return `false`
  /// to decline the jump (e.g. no further letter), which falls back to the
  /// normal accelerated step repeat for that tick.
  final bool Function(bool forward)? onLetterJump;

  /// Axis [onLetterJump] applies to. Ignored when [onLetterJump] is null.
  final LetterJumpAxis letterJumpAxis;

  /// Whether held directions speed up the longer they are held (see
  /// `_rampedRepeatInterval`). Off by default: in artwork-heavy views the
  /// accelerated cadence outruns image loading, so the cards lag behind the
  /// cursor — a fixed cadence there stays in step with the cache.
  final bool accelerateRepeats;

  /// Whether holding a direction auto-repeats. Turn it off for small fixed
  /// layouts (login forms, dialogs) where one move per press is the whole
  /// interaction: with a wrapping selection there is no boundary to stop the
  /// timer, so a held direction would otherwise spin the cursor round the form.
  final bool allowRepeat;

  /// Optional override that reports whether a text field is currently focused
  /// in the active UI layer. When provided, it takes precedence over the global
  /// focus search, preventing off-stage text fields from blocking navigation.
  final bool Function()? isTextFieldFocused;

  static final _log = LoggerService.instance;

  /// When true, all raw input events are logged for diagnostic purposes.
  static bool _debugLogging = false;
  static bool get debugLogging => _debugLogging;
  static void setDebugLogging(bool enabled) {
    _debugLogging = enabled;
    _log.i(
      '[GamepadNavigation] Debug logging ${enabled ? 'ENABLED' : 'DISABLED'}',
    );
  }

  StreamSubscription<GamepadEvent>? _subscription;
  DateTime? _lastDirectionalEventTime;
  DateTime? _lastActionEventTime;

  /// Throttle duration for directional inputs to prevent "drifting" or excessive navigation.
  static const int _directionalThrottleMs = 128;

  // ---------------------------------------------------------------------
  // Shoulder (L1/R1) tab-switch pacing.
  //
  // These are STATIC on purpose: switching a tab swaps the active navigation
  // layer, so consecutive presses are seen by *different* GamepadNavigation
  // instances. Per-instance timers would reset on every switch and let a held
  // bumper run away through the tabs.
  //
  // Android delivers a held bumper as a stream of auto-repeat ACTION_DOWNs.
  // A press that arrives without an intervening release is that stream (the
  // button is HELD) and is paced at [_shoulderRepeatIntervalMs]; a press after
  // a release is a fresh, deliberate TAP and only has to clear
  // [_shoulderTapDebounceMs].
  // ---------------------------------------------------------------------

  /// Last shoulder press actually turned into a tab switch.
  static DateTime? _lastShoulderDispatchTime;

  /// True once a shoulder release has been seen, i.e. the next press starts a
  /// new tap rather than continuing a hold.
  static bool _shoulderReleasedSinceDispatch = true;

  /// Cadence at which a HELD bumper walks the tabs (~4 tabs/second). Fast
  /// enough to cross the tab bar in one hold, still slow enough to release on
  /// the tab you want.
  static const int _shoulderRepeatIntervalMs = 255;

  /// Debounce between two separate bumper TAPS. Short, so deliberate rapid
  /// taps to skip several tabs all register.
  static const int _shoulderTapDebounceMs = 50;

  /// Safety net for a dropped release: a gap this long means the button can't
  /// still be held, so the next press counts as a fresh tap regardless.
  static const int _shoulderHoldLapsedMs = 500;

  // ---------------------------------------------------------------------
  // Desktop (Linux/Windows/macOS) synthetic shoulder repeat.
  //
  // The pacing above assumes the platform re-delivers a held bumper. Only
  // Android does: the Linux joystick API (`/dev/input/jsX`, see the vendored
  // gamepads_linux plugin) and the Windows/macOS backends report STATE CHANGES
  // only, so a held bumper is one press event and nothing more until release.
  // With nothing to pace, a hold moved exactly one tab and every tab needed its
  // own press — the Steam Deck symptom. Synthesize the repeat stream with a
  // timer instead, matching the Android cadence.
  //
  // The timer is STATIC for the same reason the pacing is: switching a tab
  // rebuilds the navigation layer, so the instance that saw the press is
  // deactivated long before the hold ends. Ticks are dispatched to whichever
  // layer is active at the time via [_activeNavigator].
  // ---------------------------------------------------------------------

  /// Navigator currently receiving input, i.e. the layer a synthetic shoulder
  /// repeat should be dispatched to.
  static GamepadNavigation? _activeNavigator;

  /// Running synthetic repeat for a held bumper on desktop.
  static Timer? _shoulderHoldTimer;

  /// Which bumper the synthetic repeat is walking with.
  static GamepadInputType? _shoulderHoldInput;

  /// Raw key + gamepad that started the hold. The release is matched on the RAW
  /// key rather than a translated event because a tab switch clears the new
  /// layer's translator state, so the release reads as "no edge" there and is
  /// dropped — the same trap the Android release check at [_handleGamepadEvent]
  /// works around. Matching the raw key needs no mapping and cannot miss.
  static String? _shoulderHoldRawKey;
  static String? _shoulderHoldGamepadId;

  /// When the current synthetic hold started, for [_shoulderHoldMaxMs].
  static DateTime? _shoulderHoldStartedAt;

  /// How long a bumper must stay down before the synthetic repeat kicks in.
  /// Longer than [_shoulderTapDebounceMs] so a normal tap never repeats.
  static const Duration _shoulderHoldStartDelay = Duration(milliseconds: 400);

  /// Hard stop for a synthetic hold. Nothing on the app side can prove the
  /// button is still down, so if the release is ever lost the tabs would cycle
  /// forever; this bounds the damage to a few seconds.
  static const int _shoulderHoldMaxMs = 10000;

  /// Debounce duration for action buttons to prevent double-presses.
  static const int _actionDebounceMs = 128;

  /// True for the raw Android keycodes of the L1/R1 bumpers.
  static bool _isAndroidShoulderKeycode(String key) {
    final k = key.toLowerCase();
    return k == 'keycode_button_l1' || k == 'keycode_button_r1';
  }

  /// Delay before the first repeat event occurs when a button is held.
  static const Duration _initialRepeatDelay = Duration(milliseconds: 300);

  /// Interval between the first few repeat events when a button is held.
  static const Duration _repeatInterval = Duration(milliseconds: 80);

  /// Fastest repeat interval reached while a direction stays held. The interval
  /// ramps from [_repeatInterval] down to this over [_rampRepeats] repeats, so
  /// a long hold accelerates instead of crawling at a fixed speed.
  static const Duration _minRepeatInterval = Duration(milliseconds: 35);

  /// Repeats taken to ramp from [_repeatInterval] to [_minRepeatInterval].
  static const int _rampRepeats = 14;

  /// How long a direction must be held before repeats escalate from stepping
  /// item-by-item to ES-DE style alphabetical jumping (see [onLetterJump]).
  /// Long enough that the accelerated step scroll (~17 items by this point) is
  /// still the normal way to browse a short list, but short enough that holding
  /// a direction to skim a big library reaches the alphabet quickly.
  static const Duration _letterJumpAfter = Duration(milliseconds: 1200);

  /// Dwell time on each letter while letter jumping — long enough to read the
  /// letter and release on it, short enough to cross the alphabet quickly.
  static const Duration _letterJumpInterval = Duration(milliseconds: 360);

  final Map<dynamic, Timer?> _repeatTimers = {};

  DateTime? _lastEventTime;
  static const int _throttleDelayMs = 128;
  bool _isActive = false;

  /// Broadcasts whether Select is currently held, so UI (e.g. the gamepad
  /// legend) can reveal the Select+face-button chord shortcuts while it is down.
  /// Only the active navigation layer drives this.
  static final ValueNotifier<bool> selectHeldNotifier = ValueNotifier(false);

  /// App-wide fallback for a plain Select (View) tap.
  ///
  /// The header notification bell registers itself here so Select opens the
  /// notifications popup from anywhere the header is on screen, without every
  /// screen having to wire up a callback it does not own. It only runs when the
  /// active layer has no [onSelectButton] of its own: a screen that already
  /// gives Select a meaning (muting the preview video, picking a save) keeps
  /// it, and never fires two actions from one press.
  static VoidCallback? globalSelectTap;

  /// Tap-vs-chord decisions for Select. See [SelectTap] for the rules.
  final SelectTap _selectTap = SelectTap();

  /// Mirrors [SelectTap.held] onto the shared notifier for the legend UI.
  void _publishSelectHeld() {
    final held = _selectTap.held;
    if (selectHeldNotifier.value != held) selectHeldNotifier.value = held;
  }

  /// Face buttons whose PRESS fired a combo and whose matching RELEASE must be
  /// swallowed so the normal action never fires (Desktop dispatches on release).
  final Set<GamepadInputType> _comboConsumed = {};

  /// Pending tap dispatch, cancelled if a chord fires inside the chord window.
  Timer? _selectTapTimer;

  /// Handles the Select press edge shared by the raw-Android and translated
  /// paths.
  void _onSelectDown(DateTime now) {
    _selectTap.press(now);
    _selectTapTimer?.cancel();
    _selectTapTimer = null;
    _publishSelectHeld();
  }

  /// Handles the Select release edge, dispatching [onSelectButton] when the
  /// hold was a plain tap so Select keeps its own action (e.g. mute the playing
  /// video) while still working as the chord modifier.
  ///
  /// The dispatch is deferred by [SelectTap.chordWindow] because the
  /// pulse-emitting controllers release Select while it is still physically
  /// held — firing immediately would mute the video at the start of every
  /// chord. Any chord landing inside that window invalidates the pending tap.
  void _onSelectUp(DateTime now) {
    final schedulesTap = _selectTap.releaseSchedulesTap(now);
    _publishSelectHeld();
    if (!schedulesTap) return;
    _selectTapTimer?.cancel();
    _selectTapTimer = Timer(SelectTap.chordWindow, () {
      _selectTapTimer = null;
      if (!_selectTap.tapStillValid) return;
      final owned = onSelectButton;
      if (owned != null) {
        owned();
        return;
      }
      globalSelectTap?.call();
    });
  }

  DateTime? _activationTime;

  /// Grace period after activation during which inputs are ignored (prevents
  /// accidental inputs from previous screens). Kept just long enough to cover
  /// the in-flight events of the press that caused the layer change; the
  /// shoulder buttons bypass it entirely (see [_handleGamepadEvent]).
  static const int _reactivationGraceMs = 150;

  String? _currentGamepadId;
  String? _currentGamepadName;

  final GamepadEventTranslator _translator = GamepadEventTranslator();

  bool _keyboardInitialized = false;

  bool get isAndroid => Platform.isAndroid;
  bool get isWindows => Platform.isWindows;
  bool get isLinux => Platform.isLinux;
  bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  GamepadNavigation({
    this.onNavigateUp,
    this.onNavigateDown,
    this.onNavigateLeft,
    this.onNavigateRight,
    this.onPreviousTab,
    this.onNextTab,
    this.onSelectItem,
    this.onBack,
    this.onFavorite,
    this.onSettings,
    this.onXButton,
    this.onLeftStickClick,
    this.onRightStickClick,
    this.onSelectButton,
    this.onLeftBumper,
    this.onRightBumper,
    this.onSelectModifierA,
    this.onSelectModifierB,
    this.onSelectModifierX,
    this.onSelectModifierY,
    this.onLetterJump,
    this.letterJumpAxis = LetterJumpAxis.vertical,
    this.accelerateRepeats = false,
    this.allowRepeat = true,
    this.isTextFieldFocused,
  });

  /// Starts listening for gamepad and keyboard events.
  void initialize() async {
    _subscription?.cancel();

    await _initializeGamepadInfo();

    _subscription = Gamepads.events.listen(
      (event) {
        try {
          _handleGamepadEvent(event);
        } catch (e, stack) {
          _log.e(
            '[GamepadNavigation] Uncaught error in event handler: $e\n$stack',
          );
        }
      },
      onError: (error, stack) {
        _log.e('[GamepadNavigation] Stream error: $error\n$stack');
      },
      cancelOnError: false,
    );

    if (!_keyboardInitialized) {
      ServicesBinding.instance.keyboard.addHandler(_handleKeyEvent);
      _keyboardInitialized = true;
    }
  }

  /// Internal setup for detecting connected gamepads and their specific quirks.
  Future<void> _initializeGamepadInfo() async {
    try {
      final gamepads = await getConnectedGamepads();

      _log.i('[GamepadNavigation] Gamepads found: ${gamepads.length}');
      for (int i = 0; i < gamepads.length; i++) {
        final g = gamepads[i];
        final deviceInfo = g.deviceInfo;
        final sysInfo = g.systemInfo;
        final vid =
            sysInfo['vendorId'] ??
            sysInfo['vid'] ??
            sysInfo['VID'] ??
            'unknown';
        final pid =
            sysInfo['productId'] ??
            sysInfo['pid'] ??
            sysInfo['PID'] ??
            'unknown';
        _log.i(
          '[GamepadNavigation] [$i] id="${g.id}" name="${g.name}" '
          'connection=${deviceInfo.connectionType.name} '
          'driver=${deviceInfo.driver ?? "unknown"} '
          'VID=$vid PID=$pid '
          'systemInfo=$sysInfo',
        );
      }

      if (gamepads.isNotEmpty) {
        final firstGamepad = gamepads.first;
        _currentGamepadId = firstGamepad.id;
        _currentGamepadName = firstGamepad.name;

        _translator.updateGamepadSystemInfo(
          firstGamepad.id,
          firstGamepad.systemInfo,
        );
        _translator.updateGamepadName(firstGamepad.id, firstGamepad.name);

        if (Platform.isLinux) {
          final connectionType = firstGamepad.deviceInfo.connectionType;
          _translator.updateGamepadConnectionType(
            firstGamepad.id,
            connectionType,
          );
        }
      }
    } catch (e) {
      _log.e('[GamepadNavigation] Error initializing gamepad info: $e');
    }
  }

  /// Ensures connection type data is available for a specific gamepad ID.
  Future<void> _ensureConnectionTypeDetected(String gamepadId) async {
    try {
      final gamepads = await getConnectedGamepads();
      final gamepad = gamepads.firstWhere(
        (g) => g.id == gamepadId,
        orElse: () => throw Exception('Gamepad not found'),
      );

      _translator.updateGamepadSystemInfo(gamepadId, gamepad.systemInfo);
      _translator.updateGamepadName(gamepadId, gamepad.name);
      final connectionType = gamepad.deviceInfo.connectionType;
      _translator.updateGamepadConnectionType(gamepadId, connectionType);
      _currentGamepadName = gamepad.name;
    } catch (e) {
      _log.e('[GamepadNavigation] Error detecting connection type: $e');
    }
  }

  /// Fires the active layer's back action, exactly as a B press would.
  ///
  /// The one seam a touch gesture needs: "back" means something different on
  /// every screen, but every screen already tells its navigator what — so the
  /// app-wide back swipe ([BackSwipeZone]) dispatches here instead of each
  /// screen growing its own gesture handler. Returns false when the top layer
  /// has no back action (or none is active), so the caller can stay silent
  /// rather than pretend something happened.
  static bool triggerBack() {
    final navigator = _activeNavigator;
    if (navigator == null || !navigator._isActive) return false;
    final onBack = navigator.onBack;
    if (onBack == null) return false;
    SfxService().playBackSound();
    onBack();
    return true;
  }

  /// Manually triggers a refresh of the connected gamepads list.
  Future<void> refreshGamepadInfo() async {
    await _initializeGamepadInfo();
  }

  /// Enables input processing for this navigator instance.
  void activate() {
    final wasInactive = !_isActive;
    _isActive = true;
    // Take over any synthetic shoulder repeat still running from the layer we
    // just displaced, so a hold keeps walking tabs across the switch.
    _activeNavigator = this;

    // Start grace period only on true transitions to prevent discarding mid-flight release events.
    if (wasInactive) {
      _activationTime = DateTime.now();
      // Clear any stale repeat timers that may have survived a prior deactivation.
      cancelAllRepeatTimers();
      // Drop remembered button states: a button held while this layer was
      // deactivated never delivered its release here, so the translator would
      // still think it is down and would ignore the next press of it.
      _translator.clearButtonStates();
    }
    _lastEventTime = null;
    _lastDirectionalEventTime = null;
    _lastActionEventTime = null;
    // Shoulder pacing is deliberately NOT reset here — it is shared across
    // layers so a held bumper keeps its cadence while tabs (and therefore
    // layers) change underneath it.
  }

  /// Disables input processing and cancels any active auto-repeat timers.
  void deactivate() {
    _isActive = false;
    _activationTime = null;
    _resetSelectModifier();
    cancelAllRepeatTimers();
    // Leave [_shoulderHoldTimer] alone: a tab switch deactivates this layer
    // while the bumper is still physically down, and the next layer picks the
    // hold up. Only the release (or the safety cap) ends it.
    if (identical(_activeNavigator, this)) _activeNavigator = null;
  }

  /// Clears Select chord-modifier state so it can't leak across layer changes
  /// (e.g. opening a dialog while Select is down).
  void _resetSelectModifier() {
    _selectTap.reset();
    _publishSelectHeld();
    _selectTapTimer?.cancel();
    _selectTapTimer = null;
    _comboConsumed.clear();
  }

  /// Whether a Select+face-button chord should register right now: Select is
  /// still reported down, or it pulsed within the chord window.
  bool _isSelectChordActive() => _selectTap.isChordActive(DateTime.now());

  /// Maps a face button to its Select-modifier combo callback, if any.
  VoidCallback? _selectModifierFor(GamepadInputType inputType) {
    switch (inputType) {
      case GamepadInputType.buttonA:
        return onSelectModifierA;
      case GamepadInputType.buttonB:
        return onSelectModifierB;
      case GamepadInputType.buttonX:
        return onSelectModifierX;
      case GamepadInputType.buttonY:
        return onSelectModifierY;
      default:
        return null;
    }
  }

  /// Cancels all active auto-repeat timers.
  ///
  /// Called when navigation lands on a text field so held directional inputs
  /// do not loop indefinitely.
  void cancelAllRepeatTimers() {
    for (final timer in _repeatTimers.values) {
      timer?.cancel();
    }
    _repeatTimers.clear();
  }

  /// Indicates if this navigator is currently processing events.
  bool get isActive => _isActive;

  /// Identifier of the currently active gamepad.
  String? get currentGamepadId => _currentGamepadId;

  /// Name of the currently active gamepad.
  String? get currentGamepadName => _currentGamepadName;

  /// Utility to fetch a list of all currently connected [GamepadController]s.
  static Future<List<GamepadController>> getConnectedGamepads() async {
    try {
      final gamepads = await Gamepads.list();
      return gamepads;
    } catch (e) {
      _log.e('[GamepadNavigation] Error listing gamepads: $e');
      return [];
    }
  }

  /// Fetches detailed information for a specific gamepad.
  static Future<GamepadController?> getGamepadInfo(String gamepadId) async {
    try {
      final gamepads = await Gamepads.list();
      return gamepads.where((gamepad) => gamepad.id == gamepadId).firstOrNull;
    } catch (e) {
      _log.e(
        '[GamepadNavigation] Error getting gamepad info for $gamepadId: $e',
      );
      return null;
    }
  }

  /// Fetches a list of standardized [GamepadInfo] objects for all connected devices.
  static Future<List<GamepadInfo>> getAllConnectedGamepadsInfo() async {
    try {
      final gamepads = await Gamepads.list();
      final gamepadInfos = <GamepadInfo>[];

      for (final gamepad in gamepads) {
        final deviceInfo = gamepad.deviceInfo;

        gamepadInfos.add(
          GamepadInfo(
            id: gamepad.id,
            name: gamepad.name,
            connectionType: deviceInfo.connectionType.name,
            driver: deviceInfo.driver,
            devicePath: gamepad.id,
            systemInfo: gamepad.systemInfo,
          ),
        );
      }

      return gamepadInfos;
    } catch (e) {
      _log.e('[GamepadNavigation] Error getting all gamepads info: $e');
      return [];
    }
  }

  /// Returns all gamepads including their active connection status.
  Future<List<GamepadInfo>> getAllGamepadsWithActiveStatus() async {
    return await getAllConnectedGamepadsInfo();
  }

  /// Releases resources held by the navigator.
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    _resetSelectModifier();
    cancelAllRepeatTimers();
    if (identical(_activeNavigator, this)) {
      _activeNavigator = null;
      _stopShoulderHold();
    }

    if (_keyboardInitialized && isDesktop) {
      ServicesBinding.instance.keyboard.removeHandler(_handleKeyEvent);
      _keyboardInitialized = false;
    }
  }

  /// Toggles the application's fullscreen state.
  Future<void> _toggleFullscreen() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      if (Platform.isWindows || Platform.isMacOS) {
        final isFullscreen = await windowManager.isFullScreen();
        await windowManager.setFullScreen(!isFullscreen);

        // Allow some time for the window manager to process the state change.
        await Future.delayed(const Duration(milliseconds: 100));
        final newState = await windowManager.isFullScreen();
        FullscreenNotifier().notifyFullscreenChanged(newState);
      }
    }
  }

  /// Orchestrates the processing of a raw [GamepadEvent].
  void _handleGamepadEvent(GamepadEvent event) async {
    // Ends a synthetic shoulder repeat. Deliberately ahead of the active check:
    // every navigator subscribes to the raw stream, and the release that ends a
    // hold can land while this layer is the deactivated one (mid tab switch, or
    // after a game launch deactivated everything). Dropping it there would
    // leave the tabs cycling until the safety cap.
    _checkShoulderHoldRelease(event);

    if (!_isActive) return;

    // NOTE: the reactivation grace period is applied AFTER translation (see
    // below) so the translator still observes every edge while the grace is
    // running. Discarding raw events here left its press/release state stuck
    // and swallowed the next genuine press.

    try {
      // Auto-detect and switch to the device emitting the event.
      if (_currentGamepadId != event.gamepadId) {
        _log.i(
          '[GamepadNavigation] Active gamepad changed: "${_currentGamepadId ?? "none"}" -> "${event.gamepadId}"',
        );
        _currentGamepadId = event.gamepadId;
        await _ensureConnectionTypeDetected(event.gamepadId);
      }

      if (_debugLogging) {
        _log.i(
          '[GamepadRaw] gamepad="${event.gamepadId}" key="${event.key}" '
          'type=${event.type.name} value=${event.value.toStringAsFixed(4)}',
        );
      }

      final now = DateTime.now();

      // Select (View) chord modifier on Android: read the RAW key directly.
      // This controller auto-repeats ACTION_DOWN (value 0.0) while the button is
      // held and doesn't reliably emit a matching ACTION_UP, so edge-detection
      // gets stuck. The raw value can't: 0.0 = down (incl. key-repeat) → held;
      // 1.0 = up → released. A hold that fires a chord dispatches nothing of its
      // own; a short tap that fires none dispatches [onSelectButton] on release.
      if (isAndroid && event.key.toLowerCase() == 'keycode_button_select') {
        if (event.value < 0.5) {
          _onSelectDown(now);
        } else {
          _onSelectUp(now);
        }
        return;
      }

      // Shoulder RELEASE is read from the RAW key, before translation, for the
      // same reason Select is (above). A tab switch activates a new navigation
      // layer, which clears its translator's button states; the release that
      // follows then looks like "no edge" to that layer and is dropped, so
      // [_shoulderReleasedSinceDispatch] stayed false and the next deliberate
      // TAP was misclassified as a held auto-repeat and paced at
      // [_shoulderRepeatIntervalMs] — a quick second tab switch was swallowed.
      // The raw event reaches every layer regardless of translator state.
      // A genuine hold emits no ACTION_UP, so held pacing is unaffected.
      // Values are inverted on this platform: 0.0 = down, 1.0 = up.
      if (isAndroid &&
          _isAndroidShoulderKeycode(event.key) &&
          event.value > 0.5) {
        _shoulderReleasedSinceDispatch = true;
      }

      final translatedEvent = _translator.translateEvent(event);

      if (translatedEvent == null) return;

      // Desktop: the pad reaches us whether or not our window has focus, so a
      // launched emulator in front of NeoStation would otherwise drive the UI
      // behind it. Deliberately placed AFTER translation, for the same reason
      // the reactivation grace below is: the translator must observe every edge
      // or its press/release state sticks and swallows the next real press.
      if (!DesktopWindowFocus.allowsInput) {
        DesktopWindowFocus.verifySoon();
        return;
      }

      final isShoulderInput =
          translatedEvent.inputType == GamepadInputType.buttonLB ||
          translatedEvent.inputType == GamepadInputType.buttonRB;

      // Reactivation grace: swallow inputs that leak in from the screen we just
      // came from. The shoulder buttons are exempt — every tab switch rebuilds
      // a navigation layer, so each switch restarted the grace and ate the next
      // L1/R1 press, which is why tabs often needed a second press. A stray
      // bumper only moves one tab and is trivially undone, unlike a stray A/B.
      if (!isShoulderInput &&
          _activationTime != null &&
          now.difference(_activationTime!).inMilliseconds <
              _reactivationGraceMs) {
        return;
      }

      // A shoulder release ends the hold, so the next press is a fresh tap.
      // Tracked statically because the release often lands on a different
      // navigation layer than the press that switched the tab.
      if (isShoulderInput && translatedEvent.isReleased) {
        _shoulderReleasedSinceDispatch = true;
      }

      if (translatedEvent.isPressed) {
        final isDirectional = [
          GamepadInputType.dpadUp,
          GamepadInputType.dpadDown,
          GamepadInputType.dpadLeft,
          GamepadInputType.dpadRight,
          GamepadInputType.leftStickX,
          GamepadInputType.leftStickY,
        ].contains(translatedEvent.inputType);

        final isShoulder = isShoulderInput;

        if (isDirectional) {
          if (!isWindows) {
            if (_lastDirectionalEventTime != null &&
                now.difference(_lastDirectionalEventTime!).inMilliseconds <
                    _directionalThrottleMs) {
              return;
            }
          }
          _lastDirectionalEventTime = now;
        } else if (isShoulder) {
          // No release since the last switch means the bumper is still held:
          // pace the repeats. A press after a release is a tap — let it
          // through immediately.
          final holdLapsed =
              _lastShoulderDispatchTime != null &&
              now.difference(_lastShoulderDispatchTime!).inMilliseconds >
                  _shoulderHoldLapsedMs;
          final isHeldRepeat = !_shoulderReleasedSinceDispatch && !holdLapsed;

          final minIntervalMs = isHeldRepeat
              ? _shoulderRepeatIntervalMs
              : _shoulderTapDebounceMs;
          if (_lastShoulderDispatchTime != null &&
              now.difference(_lastShoulderDispatchTime!).inMilliseconds <
                  minIntervalMs) {
            return;
          }
          _lastShoulderDispatchTime = now;
          _shoulderReleasedSinceDispatch = false;
        } else {
          // Select and any face button that lands during a Select chord bypass
          // the action debounce so a quick chord isn't swallowed.
          final isChordRelated =
              translatedEvent.inputType == GamepadInputType.buttonSelect ||
              (_isSelectChordActive() &&
                  _selectModifierFor(translatedEvent.inputType) != null);
          if (!isChordRelated) {
            if (_lastActionEventTime != null &&
                now.difference(_lastActionEventTime!).inMilliseconds <
                    _actionDebounceMs) {
              return;
            }
            _lastActionEventTime = now;
          }
        }

        _lastEventTime = now;
      }

      _handleTranslatedEvent(translatedEvent);
    } catch (e) {
      _log.e('Error processing gamepad event: $e');
    }
  }

  /// Logic for dispatching callbacks based on translated input types.
  void _handleTranslatedEvent(TranslatedGamepadEvent event) {
    if (!_isActive) return;

    // ANDROID: Handle text field focus by restricting navigation.
    // Allow tab switching and back button to ensure the user can always exit a focused state.
    if (isAndroid && _isTextFieldFocused()) {
      final allowedWhileTyping = {
        GamepadInputType.buttonLB,
        GamepadInputType.buttonRB,
        GamepadInputType.buttonB,
      };
      if (!allowedWhileTyping.contains(event.inputType)) return;
    }

    // Select (View) is first and foremost a chord modifier. Track its state —
    // before the press/release gate below — so a face button pressed alongside
    // it fires a combo; a tap that fires no chord falls through to the tap
    // action on release (see [_onSelectUp]). Some controllers only reliably report one edge
    // of this button, so the timestamp is stamped on BOTH press and release.
    if (event.inputType == GamepadInputType.buttonSelect) {
      final now = DateTime.now();
      if (event.isPressed) {
        _onSelectDown(now);
      } else if (event.isReleased) {
        _onSelectUp(now);
      }
      return; // Select alone only ever fires its tap action, on release.
    }

    // A face-button PRESS fires its modifier combo when Select is still held or
    // was seen within the chord window.
    if (event.isPressed && _isSelectChordActive()) {
      final modifier = _selectModifierFor(event.inputType);
      if (modifier != null) {
        // This hold unlocked a chord, so its release must not also fire the
        // plain Select tap action.
        _selectTap.chordFired();
        _selectTapTimer?.cancel();
        _selectTapTimer = null;
        _comboConsumed.add(event.inputType);
        SfxService().playNavSound();
        modifier();
        return;
      }
    }
    // Swallow the matching release so the normal action never fires for a button
    // already consumed by a combo (order-independent of when Select is released).
    if (event.isReleased && _comboConsumed.remove(event.inputType)) return;

    bool shouldProcess;

    // Directional and shoulder buttons usually fire on press.
    if (event.inputType == GamepadInputType.dpadUp ||
        event.inputType == GamepadInputType.dpadDown ||
        event.inputType == GamepadInputType.dpadLeft ||
        event.inputType == GamepadInputType.dpadRight ||
        event.inputType == GamepadInputType.leftStickX ||
        event.inputType == GamepadInputType.leftStickY ||
        event.inputType == GamepadInputType.buttonLB ||
        event.inputType == GamepadInputType.buttonRB ||
        event.inputType == GamepadInputType.buttonRT) {
      shouldProcess = event.isPressed;
    } else {
      // Standard buttons fire on press for Android, and on release for Desktop (Standard UX).
      shouldProcess = isAndroid ? event.isPressed : !event.isPressed;
    }

    if (!shouldProcess && !event.isReleased) return;

    if (event.isReleased) {
      _stopRepeatTimer(event.inputType);

      // Handle stick release specifically for X/Y axes.
      if (event.inputType == GamepadInputType.leftStickX) {
        _stopRepeatTimer(GamepadInputType.dpadLeft);
        _stopRepeatTimer(GamepadInputType.dpadRight);
      } else if (event.inputType == GamepadInputType.leftStickY) {
        _stopRepeatTimer(GamepadInputType.dpadUp);
        _stopRepeatTimer(GamepadInputType.dpadDown);
      }

      if (!shouldProcess) return;
    }

    switch (event.inputType) {
      case GamepadInputType.dpadUp:
        _handleDirectionalAction(event.inputType, onNavigateUp);
        break;

      case GamepadInputType.dpadDown:
        _handleDirectionalAction(event.inputType, onNavigateDown);
        break;

      case GamepadInputType.dpadLeft:
        _handleDirectionalAction(event.inputType, onNavigateLeft);
        break;

      case GamepadInputType.dpadRight:
        _handleDirectionalAction(event.inputType, onNavigateRight);
        break;

      case GamepadInputType.leftStickX:
        if (isWindows) {
          // GameInput reports the stick axis normalized to [-1, 1], +X = right.
          final normalizedValue = event.value;

          if (normalizedValue.abs() < 0.5) {
            _stopRepeatTimer(GamepadInputType.dpadLeft);
            _stopRepeatTimer(GamepadInputType.dpadRight);
            return;
          }

          if (normalizedValue > 0.65) {
            _handleDirectionalAction(
              GamepadInputType.dpadRight,
              onNavigateRight,
            );
          } else if (normalizedValue < -0.65) {
            _handleDirectionalAction(GamepadInputType.dpadLeft, onNavigateLeft);
          } else {
            _stopRepeatTimer(GamepadInputType.dpadLeft);
            _stopRepeatTimer(GamepadInputType.dpadRight);
          }
        } else {
          if (event.value > 0.60) {
            _handleDirectionalAction(
              GamepadInputType.dpadRight,
              onNavigateRight,
            );
          } else if (event.value < -0.60) {
            _handleDirectionalAction(GamepadInputType.dpadLeft, onNavigateLeft);
          }
        }
        break;

      case GamepadInputType.leftStickY:
        if (isWindows) {
          // GameInput reports the stick axis normalized to [-1, 1], +Y = up.
          final normalizedValue = event.value;

          if (normalizedValue.abs() < 0.5) {
            _stopRepeatTimer(GamepadInputType.dpadUp);
            _stopRepeatTimer(GamepadInputType.dpadDown);
            return;
          }

          if (normalizedValue > 0.65) {
            _handleDirectionalAction(GamepadInputType.dpadUp, onNavigateUp);
          } else if (normalizedValue < -0.65) {
            _handleDirectionalAction(GamepadInputType.dpadDown, onNavigateDown);
          } else {
            _stopRepeatTimer(GamepadInputType.dpadUp);
            _stopRepeatTimer(GamepadInputType.dpadDown);
          }
        } else {
          if (event.value > 0.60) {
            _handleDirectionalAction(GamepadInputType.dpadUp, onNavigateUp);
          } else if (event.value < -0.60) {
            _handleDirectionalAction(GamepadInputType.dpadDown, onNavigateDown);
          }
        }
        break;

      case GamepadInputType.buttonA:
        SfxService().playEnterSound();
        onSelectItem?.call();
        break;

      case GamepadInputType.buttonB:
        SfxService().playBackSound();
        onBack?.call();
        break;

      case GamepadInputType.buttonY:
        SfxService().playNavSound();
        onFavorite?.call();
        break;

      case GamepadInputType.buttonX:
        SfxService().playNavSound();
        onXButton?.call();
        break;

      case GamepadInputType.buttonStart:
        SfxService().playNavSound();
        onSettings?.call();
        break;

      // buttonSelect is handled earlier as a held modifier (see _handleTranslatedEvent
      // top): a plain tap fires onSelectButton on release, combos fire on press.

      case GamepadInputType.buttonLB:
      case GamepadInputType.buttonRB:
        if (_dispatchShoulder(event.inputType)) _startShoulderHold(event);
        break;

      // L3 (left stick click) only — the UI hint shows the Left-Stick-Click
      // icon for this action. The physical L2 trigger (buttonLT) deliberately
      // does NOT fire it.
      case GamepadInputType.leftStickButton:
        onLeftStickClick?.call();
        break;

      case GamepadInputType.rightStickButton:
        onRightStickClick?.call();
        break;

      default:
        break;
    }
  }

  /// Internal helper to detect if any TextField currently holds focus.
  bool _isTextFieldFocused() {
    if (isTextFieldFocused != null) {
      return isTextFieldFocused!();
    }

    final primaryFocus = FocusManager.instance.primaryFocus;
    if (primaryFocus == null || primaryFocus.context == null) return false;

    try {
      final textField = primaryFocus.context
          ?.findAncestorWidgetOfExactType<TextField>();
      return textField != null;
    } catch (e) {
      return false;
    }
  }

  /// Orchestrates the processing of a raw [KeyEvent] from the keyboard.
  bool _handleKeyEvent(KeyEvent event) {
    if (!_isActive || (event is! KeyDownEvent && event is! KeyUpEvent)) {
      return false;
    }

    final isKeyDown = event is KeyDownEvent;

    // Q/E (tab switching) bypass the reactivation grace for the same reason the
    // shoulder buttons do: switching tabs rebuilds a navigation layer, so the
    // grace would eat the next tab key press.
    final isTabKey =
        event.logicalKey == LogicalKeyboardKey.keyQ ||
        event.logicalKey == LogicalKeyboardKey.keyE;
    if (!isTabKey &&
        _activationTime != null &&
        DateTime.now().difference(_activationTime!).inMilliseconds <
            _reactivationGraceMs) {
      return false;
    }

    if (_debugLogging) {
      _log.i(
        '[KeyboardRaw] key="${event.logicalKey.keyLabel}" '
        'physical="${event.physicalKey.usbHidUsage.toRadixString(16)}" '
        '${isKeyDown ? "DOWN" : "UP"}',
      );
    }

    if (_isTextFieldFocused()) {
      cancelAllRepeatTimers();
      return false;
    }

    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;

    // Toggle fullscreen with Alt+Enter.
    if (key == LogicalKeyboardKey.enter && keyboard.isAltPressed) {
      if (isKeyDown) {
        _toggleFullscreen();
      }
      return true;
    }

    // Ignore keyboard shortcuts involving Control or Shift.
    if (keyboard.isControlPressed || keyboard.isShiftPressed) {
      return false;
    }

    final now = DateTime.now();

    // Keyboard throttling for directional and basic action keys.
    if (isKeyDown &&
        _lastEventTime != null &&
        now.difference(_lastEventTime!).inMilliseconds < _throttleDelayMs) {
      if (key == LogicalKeyboardKey.arrowUp ||
          key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.backspace ||
          key == LogicalKeyboardKey.escape) {
        return true;
      }
      return false;
    }

    bool handled = false;

    // WASD or Arrow Keys for directional navigation.
    if (key == LogicalKeyboardKey.keyW || key == LogicalKeyboardKey.arrowUp) {
      if (isKeyDown) {
        _handleDirectionalAction(key, onNavigateUp);
      } else {
        _stopRepeatTimer(key);
      }
      handled = true;
    } else if (key == LogicalKeyboardKey.keyS ||
        key == LogicalKeyboardKey.arrowDown) {
      if (isKeyDown) {
        _handleDirectionalAction(key, onNavigateDown);
      } else {
        _stopRepeatTimer(key);
      }
      handled = true;
    } else if (key == LogicalKeyboardKey.keyA ||
        key == LogicalKeyboardKey.arrowLeft) {
      if (isKeyDown) {
        _handleDirectionalAction(key, onNavigateLeft);
      } else {
        _stopRepeatTimer(key);
      }
      handled = true;
    } else if (key == LogicalKeyboardKey.keyD ||
        key == LogicalKeyboardKey.arrowRight) {
      if (isKeyDown) {
        _handleDirectionalAction(key, onNavigateRight);
      } else {
        _stopRepeatTimer(key);
      }
      handled = true;
    } else if (key == LogicalKeyboardKey.keyQ) {
      // Q/E are the keyboard's bumpers, so they go through the same dispatch:
      // it honours a screen's bumper override and stays silent where the
      // screen binds nothing.
      if (isKeyDown) _dispatchShoulder(GamepadInputType.buttonLB);
      handled = true;
    } else if (key == LogicalKeyboardKey.keyE) {
      if (isKeyDown) _dispatchShoulder(GamepadInputType.buttonRB);
      handled = true;
    } else if (key == LogicalKeyboardKey.enter) {
      if (isKeyDown) {
        SfxService().playEnterSound();
        onSelectItem?.call();
      }
      handled = true;
    } else if (key == LogicalKeyboardKey.backspace) {
      if (onBack != null) {
        if (isKeyDown) {
          SfxService().playBackSound();
          onBack!.call();
        }
        handled = true;
      }
    } else if (key == LogicalKeyboardKey.keyY) {
      if (isKeyDown) {
        SfxService().playNavSound();
        onFavorite?.call();
      }
      handled = true;
    } else if (key == LogicalKeyboardKey.escape) {
      if (isKeyDown) {
        SfxService().playNavSound();
        onSettings?.call();
      }
      handled = true;
    }

    if (handled) {
      if (isKeyDown) {
        _lastEventTime = now;
      }
      return true;
    }

    return false;
  }

  /// Handles a directional movement and initializes the auto-repeat timer if necessary.
  void _handleDirectionalAction(dynamic key, Function? action) {
    if (action == null) return;

    if (_repeatTimers.containsKey(key)) {
      return;
    }

    // Mutually exclusive directions: stop the opposite direction if active.
    final bool isUp =
        key == GamepadInputType.dpadUp ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.keyW;
    final bool isDown =
        key == GamepadInputType.dpadDown ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.keyS;
    final bool isLeft =
        key == GamepadInputType.dpadLeft ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.keyA;
    final bool isRight =
        key == GamepadInputType.dpadRight ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.keyD;

    if (isUp) {
      _stopRepeatTimer(GamepadInputType.dpadDown);
      _stopRepeatTimer(LogicalKeyboardKey.arrowDown);
      _stopRepeatTimer(LogicalKeyboardKey.keyS);
    }
    if (isDown) {
      _stopRepeatTimer(GamepadInputType.dpadUp);
      _stopRepeatTimer(LogicalKeyboardKey.arrowUp);
      _stopRepeatTimer(LogicalKeyboardKey.keyW);
    }
    if (isLeft) {
      _stopRepeatTimer(GamepadInputType.dpadRight);
      _stopRepeatTimer(LogicalKeyboardKey.arrowRight);
      _stopRepeatTimer(LogicalKeyboardKey.keyD);
    }
    if (isRight) {
      _stopRepeatTimer(GamepadInputType.dpadLeft);
      _stopRepeatTimer(LogicalKeyboardKey.arrowLeft);
      _stopRepeatTimer(LogicalKeyboardKey.keyA);
    }

    final moved = _runNavAction(action, false);
    if (moved) {
      SfxService().playNavSound();
    }

    // Don't auto-repeat while a text field is focused. Repeating would keep
    // moving focus away from the field and create an infinite navigation loop.
    if (_isTextFieldFocused()) {
      cancelAllRepeatTimers();
      return;
    }

    // Stop repeating once we hit a boundary so the selection doesn't feel stuck.
    if (!moved) {
      cancelAllRepeatTimers();
      return;
    }

    if (!allowRepeat) return;

    _startRepeatTimer(key, action);
  }

  /// Invokes a navigation [action], passing whether this is a [repeat] press.
  ///
  /// Returns whether the navigation actually moved. Actions that report a
  /// `bool` (e.g. list navigation that clamps at a boundary) drive whether the
  /// nav sound plays; actions that return void are treated as always-moved to
  /// preserve the legacy behavior.
  bool _runNavAction(Function action, bool repeat) {
    dynamic result;
    if (action is Function(bool)) {
      result = action(repeat);
    } else if (action is Function()) {
      result = (action as dynamic)();
    }
    return result is bool ? result : true;
  }

  /// Internal auto-repeat logic for held buttons.
  ///
  /// Repeats are self-rescheduling rather than a fixed [Timer.periodic] so the
  /// cadence can change while the button stays down: the interval ramps from
  /// [_repeatInterval] to [_minRepeatInterval], and after [_letterJumpAfter] a
  /// direction on [letterJumpAxis] switches to alphabetical jumps that dwell
  /// for [_letterJumpInterval] each.
  void _startRepeatTimer(dynamic key, Function action) {
    _repeatTimers[key]?.cancel();

    final heldSince = DateTime.now();
    final bool canLetterJump =
        onLetterJump != null && _isLetterJumpKey(key) != null;
    final bool forward = _isLetterJumpKey(key) ?? false;
    var repeats = 0;

    void schedule(Duration delay) {
      _repeatTimers[key] = Timer(delay, () {
        // Guard: if the key was removed (by _stopRepeatTimer or
        // cancelAllRepeatTimers) before this callback ran, stop here.
        if (!_repeatTimers.containsKey(key)) return;
        if (!_isActive) {
          _repeatTimers.remove(key);
          return;
        }

        final held = DateTime.now().difference(heldSince);
        if (canLetterJump &&
            held >= _letterJumpAfter &&
            onLetterJump!(forward)) {
          SfxService().playNavSound();
          schedule(_letterJumpInterval);
          return;
        }

        if (_runNavAction(action, true)) {
          SfxService().playNavSound();
        }
        repeats++;
        schedule(
          accelerateRepeats ? _rampedRepeatInterval(repeats) : _repeatInterval,
        );
      });
    }

    schedule(_initialRepeatDelay);
  }

  /// Repeat interval after [repeats] repeats, easing linearly from
  /// [_repeatInterval] down to [_minRepeatInterval].
  static Duration _rampedRepeatInterval(int repeats) {
    if (repeats >= _rampRepeats) return _minRepeatInterval;

    final from = _repeatInterval.inMilliseconds;
    final to = _minRepeatInterval.inMilliseconds;
    return Duration(
      milliseconds: from + ((to - from) * repeats / _rampRepeats).round(),
    );
  }

  /// Whether [key] is a direction on [letterJumpAxis], and if so whether it
  /// points forward (down / right). Returns null for any other key.
  bool? _isLetterJumpKey(dynamic key) {
    if (letterJumpAxis == LetterJumpAxis.vertical) {
      if (key == GamepadInputType.dpadDown ||
          key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.keyS) {
        return true;
      }
      if (key == GamepadInputType.dpadUp ||
          key == LogicalKeyboardKey.arrowUp ||
          key == LogicalKeyboardKey.keyW) {
        return false;
      }
      return null;
    }

    if (key == GamepadInputType.dpadRight ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.keyD) {
      return true;
    }
    if (key == GamepadInputType.dpadLeft ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.keyA) {
      return false;
    }
    return null;
  }

  /// Cancels an active repeat timer for a specific key.
  void _stopRepeatTimer(dynamic key) {
    _repeatTimers[key]?.cancel();
    _repeatTimers.remove(key);
  }

  /// Walks one tab for [input], honouring the per-screen bumper overrides.
  ///
  /// Screens that bind neither the override nor the tab walk (the games grid
  /// and carousel) stay silent rather than clicking: a nav sound with nothing
  /// behind it is what made the carousel's dead bumpers read as a frozen
  /// screen rather than an unbound button.
  /// Returns whether anything was bound to walk, so an unbound bumper does not
  /// start a hold-repeat that would fire into the void.
  bool _dispatchShoulder(GamepadInputType input) {
    final action = input == GamepadInputType.buttonLB
        ? (onLeftBumper ?? onPreviousTab)
        : (onRightBumper ?? onNextTab);
    if (action == null) return false;

    SfxService().playNavSound();
    action();
    return true;
  }

  /// Starts the synthetic repeat for a bumper held on desktop.
  ///
  /// No-op on Android, where the platform already delivers the hold as a stream
  /// of auto-repeat presses that the pacing in [_handleGamepadEvent] throttles.
  void _startShoulderHold(TranslatedGamepadEvent event) {
    if (isAndroid) return;

    _stopShoulderHold();
    _shoulderHoldInput = event.inputType;
    _shoulderHoldRawKey = event.originalKey.toLowerCase();
    _shoulderHoldGamepadId = event.gamepadId;
    _shoulderHoldStartedAt = DateTime.now();

    void schedule(Duration delay) {
      _shoulderHoldTimer = Timer(delay, () {
        final startedAt = _shoulderHoldStartedAt;
        final input = _shoulderHoldInput;
        if (startedAt == null || input == null) return;

        if (DateTime.now().difference(startedAt).inMilliseconds >
            _shoulderHoldMaxMs) {
          _stopShoulderHold();
          return;
        }

        // Mid tab switch the old layer is already deactivated and the new one
        // is pushed a frame later, so a tick can land with nothing active.
        // Skip it and keep the hold alive rather than ending it early.
        _activeNavigator?._dispatchShoulder(input);
        schedule(const Duration(milliseconds: _shoulderRepeatIntervalMs));
      });
    }

    schedule(_shoulderHoldStartDelay);
  }

  /// Ends the synthetic repeat when the raw event is the release of the bumper
  /// that started it. Matching on the raw key sidesteps translated-release
  /// detection, which a layer swap breaks.
  static void _checkShoulderHoldRelease(GamepadEvent event) {
    if (_shoulderHoldTimer == null) return;
    if (event.gamepadId != _shoulderHoldGamepadId) return;
    if (event.key.toLowerCase() != _shoulderHoldRawKey) return;
    // Desktop reports buttons unencoded: non-zero is down, zero is up.
    if (event.value > 0.5) return;
    // A raw release is proof the hold ended, so the next press is a fresh tap.
    // The translated release this normally comes from is lost whenever the tab
    // switch rebuilt the layer, which would pace a deliberate second tap as if
    // it were still a hold.
    _shoulderReleasedSinceDispatch = true;
    _stopShoulderHold();
  }

  /// Cancels the synthetic shoulder repeat and clears its tracking state.
  static void _stopShoulderHold() {
    _shoulderHoldTimer?.cancel();
    _shoulderHoldTimer = null;
    _shoulderHoldInput = null;
    _shoulderHoldRawKey = null;
    _shoulderHoldGamepadId = null;
    _shoulderHoldStartedAt = null;
  }
}

/// Helper utilities for grid-based navigation.
class GridNavUtils {
  /// Retrieves the current crossAxisCount based on screen responsiveness.
  static int getCurrentCrossAxisCount(BuildContext context) {
    return Responsive.getCrossAxisCount(context);
  }

  /// Calculates the new index when navigating right in a grid.
  static int navigateRight({
    required int currentIndex,
    required int crossAxisCount,
    required int maxItems,
  }) {
    int currentRow = currentIndex ~/ crossAxisCount;
    int rowStartIndex = currentRow * crossAxisCount;
    int rowEndIndex = (currentRow + 1) * crossAxisCount - 1;

    if (rowEndIndex >= maxItems) {
      rowEndIndex = maxItems - 1;
    }

    return currentIndex == rowEndIndex ? rowStartIndex : currentIndex + 1;
  }

  /// Calculates the new index when navigating left in a grid.
  static int navigateLeft({
    required int currentIndex,
    required int crossAxisCount,
    required int maxItems,
  }) {
    int currentRow = currentIndex ~/ crossAxisCount;
    int rowStartIndex = currentRow * crossAxisCount;
    int rowEndIndex = (currentRow + 1) * crossAxisCount - 1;

    if (rowEndIndex >= maxItems) {
      rowEndIndex = maxItems - 1;
    }

    return currentIndex == rowStartIndex ? rowEndIndex : currentIndex - 1;
  }

  /// Calculates the new index when navigating down in a grid.
  static int navigateDown({
    required int currentIndex,
    required int crossAxisCount,
    required int maxItems,
  }) {
    int nextIndex = currentIndex + crossAxisCount;
    return nextIndex >= maxItems ? currentIndex % crossAxisCount : nextIndex;
  }

  /// Calculates the new index when navigating up in a grid.
  static int navigateUp({
    required int currentIndex,
    required int crossAxisCount,
    required int maxItems,
  }) {
    if (currentIndex < crossAxisCount) {
      int currentColumn = currentIndex % crossAxisCount;
      int lastRowStartIndex =
          ((maxItems - 1) ~/ crossAxisCount) * crossAxisCount;
      int newIndex = lastRowStartIndex + currentColumn;

      return newIndex >= maxItems ? newIndex - crossAxisCount : newIndex;
    } else {
      return currentIndex - crossAxisCount;
    }
  }

  static int navigateRightWithContext({
    required BuildContext context,
    required int currentIndex,
    required int maxItems,
  }) {
    final crossAxisCount = getCurrentCrossAxisCount(context);
    return navigateRight(
      currentIndex: currentIndex,
      crossAxisCount: crossAxisCount,
      maxItems: maxItems,
    );
  }

  static int navigateLeftWithContext({
    required BuildContext context,
    required int currentIndex,
    required int maxItems,
  }) {
    final crossAxisCount = getCurrentCrossAxisCount(context);
    return navigateLeft(
      currentIndex: currentIndex,
      crossAxisCount: crossAxisCount,
      maxItems: maxItems,
    );
  }

  static int navigateDownWithContext({
    required BuildContext context,
    required int currentIndex,
    required int maxItems,
  }) {
    final crossAxisCount = getCurrentCrossAxisCount(context);
    return navigateDown(
      currentIndex: currentIndex,
      crossAxisCount: crossAxisCount,
      maxItems: maxItems,
    );
  }

  static int navigateUpWithContext({
    required BuildContext context,
    required int currentIndex,
    required int maxItems,
  }) {
    final crossAxisCount = getCurrentCrossAxisCount(context);
    return navigateUp(
      currentIndex: currentIndex,
      crossAxisCount: crossAxisCount,
      maxItems: maxItems,
    );
  }
}

typedef VoidCallback = void Function();
