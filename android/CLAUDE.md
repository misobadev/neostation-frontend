# Android native layer — CLAUDE.md

Applies to `MainActivity.kt`, `SecondaryDisplayActivity.kt`, `SecondaryAppsPresentation.kt`, and the Android manifests.
Moved out of the root `CLAUDE.md` so it loads when you work under `android/` rather than in every session.

**No accessibility service.** NeoStation used to declare one, for a screenshot button and to notice a dock app closing on the bottom screen. Declaring it is enough for Play Protect to warn about or block sideloaded installs. Its permission-free replacement is below. Do not add one back.

**On Android 10+ the bottom screen is `SecondaryDisplayActivity`, a real activity in its own task on the secondary display.** Android 9 and older keep the sub_screen plugin's `Presentation` (`SecondaryAppsPresentation`). `MainActivity.launchSubScreen` picks between them, which is why the vendored plugin's `launchSubScreen` is `protected open`. Being an activity is what makes Android report what happens on that display:
- An app or game launched there covers the bottom-screen activity (onPause/onStop).
- Closing that app or game brings the activity back: `onResume`, then `onTopResumedActivityChanged(true)`. Force-stop and BACK both trigger this.

`MainActivity` uses this signal for two things:
- **Dock apps**: they need no hide/restore at all.
- **Games on the other screen**: those sessions end exactly when the game closes. `bottomScreenTracksGame`, `onBottomScreenResumed`, and Dart's `GameSessionManager.gameOnOtherScreen` make sure focus coming back to the top screen does not end the session early.

The secondary UI's engine is `BottomScreenEngine`. It is created from the plugin's `FlutterEngineGroup` with the `subDisplay` entrypoint, so the shared state works as before. It outlives the activity.

**Focus.** Android 10 multi-resume keeps both activities resumed, but only one display is focused, and the focused display is where gamepad keys go. The bottom activity becomes the top resumed one when it starts and whenever an app on its display closes, which moves focus away from the top screen. `MainActivity.onBottomScreenTopResumed` hands focus back with `ActivityManager.moveTaskToFront`. That call needs `REORDER_TASKS`. Unlike `startActivity` with `REORDER_TO_FRONT`, it does not deliver a new intent, so `MainActivity` is not paused and resumed. It is skipped while `MainActivity` is covered on its own display (`isTopCovered`), so a game there is never pulled behind NeoStation.

The bottom window keeps `FLAG_NOT_FOCUSABLE | FLAG_ALT_FOCUSABLE_IM`:
- A tap on the bottom screen does not move focus there.
- An IME pinned to the bottom screen (AYN Thor `ime_show_on_second`) stays above the panel.

BACK is swallowed in both activities.

**Swap screens** (General settings, `user_config.swap_screens`) trades the two Flutter engines between the two `FlutterView`s (`MainActivity.applyScreenSwap`). Both engines keep running; only where they draw changes. Moving the tasks between displays does not work: Android starts a second `MainActivity` with a second engine instead of moving the existing one.

Focus follows the main UI. While swapped:
- The bottom window is focusable and `MainActivity`'s is not.
- Focus is handed to the bottom task.
- The bottom activity forwards keys and motion through `MainActivity.handleGamepadKey`/`handleGamepadMotion`, so BACK swallowing, the launch block and the gamepads plugin behave the same.
- Dock apps open on the screen that shows the dock.

`MainActivity` reads the setting from the database before `super.onCreate`, because `super.onCreate` starts the bottom screen.

**SECONDARY_HOME.** `.SecondaryHome` is an `activity-alias` of the bottom activity. When NeoStation is the default launcher, Android makes it the secondary display's home: it shows at boot, and HOME pressed on the bottom screen returns to it instead of the device's `SecondaryDisplayLauncher`. Two constraints:
- Android refuses a `singleInstance`/`singleTask` activity as a secondary home, so the bottom activity is `singleTop` with its own `taskAffinity`.
- The alias is disabled (`setSecondaryHomeEnabled`) while the user hides the bottom screen. Otherwise Android would keep bringing it back.

**Home from NeoStation's top screen** (not the default launcher) moves the bottom task behind the device's own bottom launcher (`moveTaskToBack`). `onResume` brings it back. This is the activity version of the Presentation's `presentationHiddenForHome`.

**Android 9 and older (Presentation path).** A `Presentation` is a `Dialog`: cancelable and focusable by default. Tapping the bottom screen focuses that window, and BACK then runs `Dialog.cancel()` -> `FlutterPresentation.dismiss()`, which destroys the secondary engine. The presentation is therefore made safe with three things:
- `setCancelable(false)`.
- A BACK-swallowing `dispatchKeyEvent`.
- `FLAG_NOT_FOCUSABLE`.

On this path, a dock app or a game on the bottom display is revealed by hiding the presentation (`hideSecondaryForApp`). With no signal from that display, it is restored when `MainActivity` resumes.

**Reproducing BACK and focus bugs needs NeoStation set as the default launcher, after a reboot.** Otherwise BACK takes Android 13's predictive-back path, which no-ops, and neither `adb shell input keyevent 4` nor an edge swipe reproduces the classic `KEYCODE_BACK` dispatch. On the AYN Thor the bottom screen is **display 4**. On the `NeoStation_Thor` AVD it is display 2: `adb shell input -d 2 ...`, and `adb emu screenrecord screenshot <dir> --display 1` to capture it.

**A game launched on the other screen never pauses `MainActivity`.** The per-system/per-game launch screen (`user_launch_display`, `LaunchDisplayService`) sends `launch_display` = `"primary"` (display 0) or `"secondary"` (the first other display) with `launchGenericIntent`. With no setting, nothing is sent and Android launches where it always did.

When the resolved display is not this activity's, `startGameOnOtherDisplay` stamps `gameLaunchTimestamp` itself (onPause never does). If the bottom activity is on that display, it tells Dart (`onGameOnOtherScreen`) and waits for that activity to come back. Otherwise (Android 9 and older, or the bottom screen hidden), the session ends when `MainActivity` regains focus, ignoring edges in the first 5 s as the handoff.

`EmulatorLauncher.startOnDisplay` checks `isActivityStartAllowedOnDisplay` and falls back to a plain launch, so a refused display never blocks the game.
