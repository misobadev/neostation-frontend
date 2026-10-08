part of '../sqlite_config_provider.dart';

/// Secondary-display integration for [SqliteConfigProvider].
///
/// Owns the native platform-channel handling for the dual-screen subscreen:
/// connect/disconnect events, screenshot-access requests, in-game state resets,
/// and re-applying the persisted visibility setting. Extracted verbatim from the
/// host, which retains the class declaration, all state, and lifecycle wiring.
/// `notifyListeners()` routes through the host's `_notify()` bridge and the
/// statics `_log`/`_secondaryDisplayChannel` are host-qualified (both required
/// from an extension).
extension SqliteConfigSecondaryDisplay on SqliteConfigProvider {
  /// Toggles the visibility of the secondary display on dual-screen hardware.
  Future<void> updateHideBottomScreen(
    bool value, {
    int? backgroundColor,
  }) async {
    _config = _config.copyWith(hideBottomScreen: value);
    await SqliteConfigService.saveConfig(_config);

    if (Platform.isAndroid && _secondaryDisplayState != null) {
      final current = _secondaryDisplayState!.value;
      if (current != null) {
        _secondaryDisplayState!.updateState(
          systemName: current.systemName,
          gameFanart: current.gameFanart,
          gameWheel: current.gameWheel,
          gameVideo: current.gameVideo,
          isGameSelected: current.isGameSelected,
          isVideoMuted: current.isVideoMuted,
          hideBottomScreen: value,
          backgroundColor: backgroundColor ?? current.backgroundColor,
          muteToggleTrigger: current.muteToggleTrigger,
          // Hiding deactivates the secondary; un-hiding reactivates it. Mirror
          // the toggle directly — preserving the prior value would leave it
          // stuck inactive, since hiding has already forced it false.
          isSecondaryActive: !value,
        );
        if (!value) {
          // ignore: unawaited_futures
          refreshSecondaryScreenshotAccess();
        }
      }
    }

    if (Platform.isAndroid) {
      SqliteConfigProvider._secondaryDisplayChannel.invokeMethod(
        'setSecondaryDisplayVisible',
        {'visible': !value},
      );
    }

    _notify();
  }

  /// Handles native→Dart method calls for secondary display events.
  Future<dynamic> _handleSecondaryDisplayCall(MethodCall call) async {
    switch (call.method) {
      case 'onSecondaryDisplayConnected':
        if (_config.hideBottomScreen) {
          SqliteConfigProvider._log.i(
            'Secondary display connected but hidden by user preference',
          );
        } else {
          SqliteConfigProvider._log.i(
            'Secondary display connected, activating',
          );
        }
        _onSecondaryDisplayChanged(
          connected: call.method == 'onSecondaryDisplayConnected',
        );
        break;
      case 'onSecondaryDisplayDisconnected':
        SqliteConfigProvider._log.i('Secondary display disconnected');
        _onSecondaryDisplayChanged(connected: false);
        break;
      case 'onAccessibilityConnected':
        // The user just enabled the Screen Return service (e.g. via the in-game
        // launcher nudge). Re-push access state so the secondary display clears
        // the launcher warning badge and reveals the screenshot button — this
        // fires even while a game keeps the main engine backgrounded.
        // ignore: unawaited_futures
        refreshSecondaryScreenshotAccess();
        break;
    }
  }

  /// Updates secondary display state when a physical display is connected or disconnected.
  void _onSecondaryDisplayChanged({required bool connected}) {
    if (_secondaryDisplayState == null) return;

    if (connected && !_config.hideBottomScreen) {
      _secondaryDisplayState!.updateState(
        isSecondaryActive: true,
        nowPlayingDimDelay: _config.nowPlayingDimDelay,
        nowPlayingDimLevel: _config.nowPlayingDimLevel,
        fanartDimLevel: _config.fanartDimLevel,
        dockApps: _config.dockApps,
        dockEnabled: _config.dockEnabled,
        dockSlotCount: _config.dockSlotCount,
        sfxEnabled: _config.sfxEnabled,
        sfxVolume: _config.sfxVolume,
        customSfx: _config.customSfx,
        use12HourClock: _config.use12HourClock,
        // If the main UI is already up (e.g. a display hot-connected after
        // launch), carry the ready latch so the dock slides in on connect;
        // during cold boot this is still false and the dock stays parked until
        // [markAppReady] fires at first frame.
        appReady: _appReady,
      );
      // ignore: unawaited_futures
      refreshSecondaryScreenshotAccess();
    } else {
      _secondaryDisplayState!.updateState(isSecondaryActive: false);
    }
    _notify();
  }

  /// Latches the main UI as ready and pushes it to the secondary display so the
  /// app dock slides up into place. Called once, from the main screen's first
  /// post-frame callback. Idempotent — safe to call more than once.
  ///
  /// Fires at first frame, which is *before* the provider's async init assigns
  /// [_secondaryDisplayState] and seeds the shared state, so it can't rely on
  /// that field. It pushes through [SecondaryDisplayState.instance] directly,
  /// after [initialSync] so it doesn't race retained-state restoration; the
  /// copyWith-based [updateState] merges, flipping only `appReady`. Every later
  /// push copyWith's from this local state, so the latch persists.
  void markAppReady() {
    if (_appReady) return;
    _appReady = true;
    if (!Platform.isAndroid) return;
    final state = SecondaryDisplayState.instance;
    unawaited(() async {
      // Only await initialSync when the sync is still pending. When the singleton
      // was constructed *after* the shared-state cache was already populated (the
      // secondary engine broadcasts its startup state before the main engine
      // first touches the singleton), sub_screen takes its cached-construction
      // path and leaves `initialSync` (a `late final`) UNASSIGNED — a bare
      // `await state.initialSync` then throws LateInitializationError, which the
      // unawaited wrapper swallows, so `appReady` never propagates and the dock
      // never slides in. A non-null value means that cached path was taken (sync
      // already done), so skip the await. Mirrors the same guard in
      // SqliteConfigProvider's init (see `value == null` check there).
      if (state.value == null) {
        await state.initialSync;
      }
      await state.updateState(appReady: true);
    }());
  }

  /// Tells the secondary display whether the first-run setup wizard is on
  /// screen, so it can keep the app dock and all-apps launcher parked while the
  /// user is still setting up. [markAppReady] latches at the main engine's
  /// first frame, which happens behind the wizard, so the dock would otherwise
  /// slide up before there's an app to dock into.
  ///
  /// Pushes through [SecondaryDisplayState.instance] with the same
  /// cached-construction guard as [markAppReady] — the wizard runs before the
  /// provider has finished its async init, so `_secondaryDisplayState` may
  /// still be null here.
  void setSetupWizardActive(bool active) {
    if (!Platform.isAndroid) return;
    final state = _secondaryDisplayState ?? SecondaryDisplayState.instance;
    unawaited(() async {
      // See markAppReady: a bare await on an unassigned late final throws.
      if (state.value == null) {
        await state.initialSync;
      }
      await state.updateState(setupWizardActive: active);
    }());
  }

  void _onSecondaryStateChanged() {
    final state = _secondaryDisplayState?.value;
    if (state != null) {
      if (state.muteToggleTrigger > _lastMuteToggleTrigger) {
        _lastMuteToggleTrigger = state.muteToggleTrigger;
        // ignore: unawaited_futures
        toggleVideoSound();
      }
      if (state.screenshotTrigger > _lastScreenshotTrigger) {
        _lastScreenshotTrigger = state.screenshotTrigger;
        // ignore: unawaited_futures
        _handleSecondaryScreenshotRequest();
      }
      if (state.dockEditTrigger > _lastDockEditTrigger) {
        _lastDockEditTrigger = state.dockEditTrigger;
        // The secondary already shows the new layout; persist it on the main
        // engine (the source of truth for SQLite).
        // ignore: unawaited_futures
        updateDockApps(state.dockApps);
      } else if (_initialized &&
          (!listEquals(state.dockApps, _config.dockApps) ||
              state.dockEnabled != _config.dockEnabled ||
              state.dockSlotCount != _config.dockSlotCount ||
              state.nowPlayingDimDelay != _config.nowPlayingDimDelay ||
              state.nowPlayingDimLevel != _config.nowPlayingDimLevel ||
              state.fanartDimLevel != _config.fanartDimLevel ||
              state.sfxEnabled != _config.sfxEnabled ||
              state.sfxVolume != _config.sfxVolume ||
              CustomSfx.encode(state.customSfx) !=
                  CustomSfx.encode(_config.customSfx) ||
              (state.use12HourClock != null &&
                  state.use12HourClock != _config.use12HourClock) ||
              (ScreenshotService.lastKnownAccess != null &&
                  state.screenshotAccessEnabled !=
                      ScreenshotService.lastKnownAccess))) {
        // No edit trigger, yet a main-owned field in the shared snapshot
        // disagrees with the persisted config — this is a stale echo from the
        // secondary, whose startup snapshot synced before (or raced) our boot
        // seed and shipped its defaults back, clobbering the seeded values.
        // Most visible as the dock slot count snapping back to its default (3)
        // after a reboot when neostation is the home launcher and the secondary
        // engine broadcasts its default state first. None of these fields are
        // ever changed from the secondary engine (dock app edits go through
        // dockEditTrigger above), so the main engine owns them and we re-assert
        // the persisted values whenever they drift. (Guarded on _initialized so
        // we don't fight before the config has loaded.)
        //
        // screenshotAccessEnabled rides along for the same reason: its default
        // is false, so the same boot echo made the dock treat an already-granted
        // Screen Return as revoked — every filled slot guarded behind the
        // "enable Screen Return" explainer until the user opened Secondary
        // settings. Only re-asserted once we've actually checked with Android
        // (null = not checked yet), so we never push a guessed `false`.
        _secondaryDisplayState?.updateState(
          dockApps: _config.dockApps,
          dockEnabled: _config.dockEnabled,
          dockSlotCount: _config.dockSlotCount,
          nowPlayingDimDelay: _config.nowPlayingDimDelay,
          nowPlayingDimLevel: _config.nowPlayingDimLevel,
          fanartDimLevel: _config.fanartDimLevel,
          sfxEnabled: _config.sfxEnabled,
          sfxVolume: _config.sfxVolume,
          customSfx: _config.customSfx,
          use12HourClock: _config.use12HourClock,
          screenshotAccessEnabled: ScreenshotService.lastKnownAccess,
        );
      }
    }
  }

  /// Responds to a screenshot request from the secondary display: fires a system
  /// screenshot of the main screen, or opens accessibility settings if the user
  /// hasn't granted screenshot access yet.
  Future<void> _handleSecondaryScreenshotRequest() async {
    final taken = await ScreenshotService.takeScreenshot();
    if (!taken) {
      await ScreenshotService.openAccessSettings();
    }
  }

  /// Clears any stale in-game state on the secondary display. Used when the app
  /// regains focus without an active game (e.g. after quitting mid-game and
  /// relaunching), so the Now Playing panel doesn't linger.
  void resetSecondaryInGameState() {
    _secondaryDisplayState?.updateState(
      nowPlayingActive: false,
      showAchievementPanel: false,
    );
  }

  /// Pushes a known screenshot-access state to the secondary display so it can
  /// show or hide the in-game screenshot button.
  void pushScreenshotAccess(bool enabled) {
    _secondaryDisplayState?.updateState(screenshotAccessEnabled: enabled);
  }

  /// Checks current screenshot access and pushes it to the secondary display.
  ///
  /// Runs the check even when there's no secondary state yet: it refreshes
  /// [ScreenshotService.lastKnownAccess], which is what corrects a later stale
  /// echo from the secondary engine.
  Future<void> refreshSecondaryScreenshotAccess() async {
    final enabled = await ScreenshotService.isAccessEnabled();
    _secondaryDisplayState?.updateState(screenshotAccessEnabled: enabled);
  }

  /// Re-applies the persisted secondary display visibility setting to the native
  /// side. Used as a safety net when the app resumes after a display reconnection
  /// event that may have auto-created the subscreen before our native gate could
  /// intercept it.
  void reapplySecondaryDisplay() {
    if (!Platform.isAndroid) return;
    if (_config.hideBottomScreen) {
      // ignore: unawaited_futures
      SqliteConfigProvider._secondaryDisplayChannel.invokeMethod(
        'setSecondaryDisplayVisible',
        {'visible': false},
      );
      _onSecondaryDisplayChanged(connected: false);
    }
  }
}
