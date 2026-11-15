package com.neogamelab.neostation

import android.os.Bundle
import android.util.Log
import android.view.Display
import android.view.KeyEvent
import android.view.WindowManager
import com.hcoderlee.subscreen.sub_screen.FlutterPresentation
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * A [FlutterPresentation] that additionally registers a MethodChannel on the
 * secondary display's Flutter engine, so the bottom-screen app dock can list,
 * icon-load and launch Android apps directly (the secondary engine cannot reach
 * the main app's "/game" channel — that's why other secondary features signal
 * the main engine through shared state instead).
 *
 * The base class creates and owns the engine in a private field and its
 * show()/dismiss() rely on it, so we let [onCreate] run normally and then reach
 * that engine via reflection to attach our channel. The field name is pinned by
 * our vendored copy of `sub_screen` in `packages/`.
 */
class SecondaryAppsPresentation(
    private val activity: MainActivity,
    display: Display,
    entryPointFun: String
) : FlutterPresentation(activity, display, entryPointFun) {

    companion object {
        private const val TAG = "SecondaryApps"
        private const val CHANNEL = "com.neogamelab.neostation/secondary_apps"
    }

    private var appsChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        hardenAgainstDismissal()
        registerAppsChannel()
    }

    /**
     * Keeps the bottom screen alive when the user interacts with it.
     *
     * A [android.app.Presentation] is a [android.app.Dialog], so out of the box
     * it is cancelable: tapping the bottom screen moves input focus to this
     * window, and the next BACK press runs Dialog's default handling —
     * cancel() then [dismiss] — which tears the secondary FlutterView off its
     * engine and destroys it. The bottom half of the launcher then disappears
     * for good (the system launcher shows through) while the top half keeps
     * running, and nothing recreates it because the activity still holds the
     * dismissed Presentation. MainActivity already swallows BACK, but that only
     * covers its own window — this one is separate and never saw the key.
     *
     * Focus is the deeper problem: a focusable window here also makes the
     * bottom display the top-focused display, which is why HOME could relaunch
     * NeoStation onto the bottom screen (or re-prompt for the default launcher)
     * and why gamepad keys stopped reaching MainActivity after a tap. The
     * bottom screen is a touch-only status/dock surface with no text fields or
     * key handling of its own, so it never needs key focus: FLAG_NOT_FOCUSABLE
     * keeps touch working while leaving every key event, and the focused
     * display, with the main activity on top.
     *
     * FLAG_ALT_FOCUSABLE_IM rides along because FLAG_NOT_FOCUSABLE on its own
     * also declares "this window does not interact with the input method", and
     * such a window is layered *above* the IME window on its display. Dual-screen
     * handhelds can pin the keyboard to the bottom screen (on the AYN Thor,
     * Settings.System `ime_show_on_second`), and there the IME window is created
     * on this display while the edit field stays on the main one — so our
     * full-screen panel simply covered it and typing anywhere in NeoStation
     * showed no keyboard at all. Adding the flag inverts only that IME
     * relationship ("behind/away from the IME") and leaves key focus where it
     * is: still not focusable, so this window can never become the IME target.
     */
    private fun hardenAgainstDismissal() {
        setCancelable(false)
        setCanceledOnTouchOutside(false)
        try {
            window?.addFlags(
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM
            )
        } catch (e: Exception) {
            Log.w(TAG, "Could not make secondary window non-focusable: ${e.message}")
        }
    }

    /** Never let BACK reach Dialog's cancel path, focused or not. */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.keyCode == KeyEvent.KEYCODE_BACK) return true
        return super.dispatchKeyEvent(event)
    }

    // Deprecated since API 33, but Dialog still routes BACK through it and the
    // override must stay for the platforms that do.
    @Deprecated("Dialog still routes BACK through this override on older platforms.")
    override fun onBackPressed() {
        // Deliberately empty: BACK must never dismiss the bottom screen.
    }

    private fun registerAppsChannel() {
        val engine = resolveEngine()
        if (engine == null) {
            Log.e(TAG, "Could not resolve secondary FlutterEngine; dock channel unavailable")
            return
        }
        appsChannel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInstalledApps" -> {
                        val includeSystem = call.argument<Boolean>("includeSystemApps") ?: false
                        activity.getInstalledApps(includeSystem, result)
                    }
                    "getAppIcon" -> {
                        val pkg = call.argument<String>("packageName")
                        if (pkg != null) {
                            activity.getAppIcon(pkg, result)
                        } else {
                            result.error("INVALID_ARGUMENTS", "Package name is required", null)
                        }
                    }
                    "launchAppOnSecondary" -> {
                        val pkg = call.argument<String>("packageName")
                        if (pkg != null) {
                            activity.launchPackageOnSecondaryDisplay(pkg, result)
                        } else {
                            result.error("INVALID_ARGUMENTS", "Package name is required", null)
                        }
                    }
                    "openAccessibilitySettings" -> {
                        activity.openScreenshotAccessSettings()
                        result.success(null)
                    }
                    "isDisplayOn" -> result.success(isDisplayOn())
                    else -> result.notImplemented()
                }
            }
        }
    }

    /**
     * Live power state of the display this presentation renders on — the ground
     * truth for "is the bottom screen actually lit". The secondary engine gets
     * no Android lifecycle callbacks and its shared-state mirror of the screen
     * flag travels on a transport that ships full snapshots with no ordering
     * guarantee, so a stale snapshot can resurrect a `true` after the device has
     * gone to sleep. Asking the display itself can't go stale.
     *
     * Fails open (true): a display we cannot read must not silently disable the
     * preview while the device is awake.
     */
    private fun isDisplayOn(): Boolean {
        return try {
            getDisplay().state == Display.STATE_ON
        } catch (e: Exception) {
            Log.w(TAG, "Could not read secondary display state: ${e.message}")
            true
        }
    }

    /**
     * Pushes a device screen on/off edge straight to the secondary engine.
     * Direct and ordered, unlike the shared-state snapshot mirror, so the engine
     * can tear its preview video down on sleep and know the teardown sticks.
     * Must be called on the main thread.
     */
    fun notifyScreenState(on: Boolean) {
        try {
            appsChannel?.invokeMethod(
                if (on) "onDeviceScreenOn" else "onDeviceScreenOff",
                null
            )
        } catch (e: Exception) {
            Log.e(TAG, "notifyScreenState failed: ${e.message}")
        }
    }

    /** Reads the base class's private engine field created during onCreate. */
    private fun resolveEngine(): FlutterEngine? {
        return try {
            val field = FlutterPresentation::class.java.getDeclaredField("flutterEngine")
            field.isAccessible = true
            field.get(this) as? FlutterEngine
        } catch (e: Exception) {
            Log.e(TAG, "Reflection for secondary engine failed: ${e.message}")
            null
        }
    }

    override fun dismiss() {
        appsChannel?.setMethodCallHandler(null)
        appsChannel = null
        super.dismiss()
    }
}
