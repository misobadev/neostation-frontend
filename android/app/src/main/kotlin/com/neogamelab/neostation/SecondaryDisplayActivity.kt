package com.neogamelab.neostation

import android.app.Activity
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.Display
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.FrameLayout
import com.hcoderlee.subscreen.sub_screen.FlutterEngineHelper
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterSurfaceView
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineGroupCache
import io.flutter.embedding.engine.dart.DartExecutor.DartEntrypoint
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/**
 * The bottom screen of a dual-screen handheld, as an Activity of its own on
 * the secondary display (Android 10+; older versions keep
 * [SecondaryAppsPresentation]).
 *
 * Being a real Activity in its own task is what makes Android report what
 * happens on that display: an app or game launched there covers this activity
 * (onPause/onStop), and closing it brings this activity back (onResume and
 * [onTopResumedActivityChanged]). A Presentation gets none of that, which is why
 * the bottom screen used to need an accessibility service to notice a dock app
 * closing.
 *
 * Rules this activity keeps:
 * - The gamepad always drives the main UI. Android keeps one focused display
 *   and moves it here when this activity starts, when an app on this display
 *   closes, or on a tap. Keys that reach this window while it shows the
 *   secondary UI go to the main UI ([MainActivity.dispatchKeyFromSecondaryUi])
 *   and focus is handed back. With the screens swapped the roles flip: this
 *   window shows the main UI, and the top one forwards here.
 * - Its window stays focusable (see [focusFlagsFor]). Android treats the top
 *   display that has a focused activity as the focused one even when that
 *   activity's window cannot take focus, and then a key waits for a window
 *   that never comes: NeoStation is reported as not responding after 5 s.
 * - BACK never finishes it.
 * - Its Flutter engine ([BottomScreenEngine]) outlives it, so a recreate does
 *   not restart the secondary UI.
 */
class SecondaryDisplayActivity : Activity() {

    companion object {
        private const val TAG = "SecondaryDisplay"

        @Volatile
        private var current: WeakReference<SecondaryDisplayActivity>? = null

        /** The live instance, if the bottom screen is up. */
        val instance: SecondaryDisplayActivity?
            get() = current?.get()?.takeUnless { it.isFinishing || it.isDestroyed }

        /** Whether Android 10's multi-resume, which this design relies on, is available. */
        val isSupported: Boolean
            get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
    }

    private var flutterView: FlutterView? = null

    /** Android's top resumed activity: this display is the focused one. */
    var isTopResumed = false
        private set

    /** True between onPause and the next onResume: something covers this screen. */
    var isCovered = false
        private set

    /** Display this activity is on, or -1 before it has a window. */
    val displayId: Int
        get() = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display?.displayId ?: -1
            else @Suppress("DEPRECATION") windowManager.defaultDisplay.displayId
        } catch (e: Exception) {
            -1
        }

    private val main: MainActivity?
        get() = MainActivity.instance

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        current = WeakReference(this)
        Log.i(TAG, "onCreate on display $displayId")

        val view = FlutterView(this, FlutterSurfaceView(this, false))
        view.layoutParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
        )
        setContentView(view)
        flutterView = view
        hideSystemBars()

        view.attachToFlutterEngine(BottomScreenEngine.obtain(this))
        // With the screens swapped, MainActivity trades engines with this view
        // here, and sets the focus roles of both windows.
        main?.onBottomScreenReady(this) ?: applyFocusRole()
    }

    private fun hideSystemBars() {
        androidx.core.view.WindowCompat.setDecorFitsSystemWindows(window, false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.let {
                it.hide(WindowInsets.Type.systemBars())
                it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (
                android.view.View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                    android.view.View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                    android.view.View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                    android.view.View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                    android.view.View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                    android.view.View.SYSTEM_UI_FLAG_FULLSCREEN
                )
        }
    }

    /** This window's side of the focus rule in [focusFlagsFor]. */
    fun applyFocusRole() {
        val m = main
        val engine = m?.mainEngine
        val showsMainUi = engine != null && flutterView?.attachedFlutterEngine === engine
        val flags = focusFlagsFor(showsMainUi, mainUiCovered = m?.isMainUiCovered() == true)
        window.setFlags(
            flags,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM
        )
    }

    /** The view drawing this screen, for [MainActivity]'s screen swap. */
    fun screenView(): FlutterView? = flutterView

    override fun onResume() {
        super.onResume()
        val wasCovered = isCovered
        isCovered = false
        flutterView?.attachedFlutterEngine?.lifecycleChannel?.appIsResumed()
        main?.onBottomScreenCoveredChanged()
        main?.onBottomScreenResumed(this, wasCovered)
    }

    override fun onPause() {
        super.onPause()
        isCovered = true
        main?.onBottomScreenCoveredChanged()
    }

    override fun onTopResumedActivityChanged(isTopResumedActivity: Boolean) {
        super.onTopResumedActivityChanged(isTopResumedActivity)
        isTopResumed = isTopResumedActivity
        if (isTopResumedActivity) main?.onBottomScreenTopResumed(this)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && !showsMainUi()) main?.onSecondaryUiFocused()
    }

    private fun showsMainUi(): Boolean {
        val engine = main?.mainEngine ?: return false
        return flutterView?.attachedFlutterEngine === engine
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.keyCode == KeyEvent.KEYCODE_BACK) return true
        val m = main ?: return super.dispatchKeyEvent(event)
        if (showsMainUi()) {
            // Swapped: the gamepad drives the main UI here, through the same
            // handling the top screen uses.
            if (m.handleGamepadKey(event)) return true
            return super.dispatchKeyEvent(event)
        }
        if (m.dispatchKeyFromSecondaryUi(event)) return true
        // Only volume keys and keys the main UI left fall through. The
        // secondary UI is touch-only, so they never reach its view.
        return if (org.flame_engine.gamepads_android.EventListener.isSystemKey(event.keyCode)) {
            super.dispatchKeyEvent(event)
        } else {
            false
        }
    }

    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean {
        val m = main ?: return super.dispatchGenericMotionEvent(event)
        if (showsMainUi()) {
            if (m.handleGamepadMotion(event)) return true
            return super.dispatchGenericMotionEvent(event)
        }
        return m.dispatchMotionFromSecondaryUi(event)
    }

    @Deprecated("Still routed on older platforms; BACK must never finish the bottom screen.")
    override fun onBackPressed() {
        // Deliberately empty.
    }

    /** Finishes the bottom screen and releases its engine (screen hidden or gone). */
    fun close() {
        flutterView?.let { view ->
            main?.onBottomScreenClosing(this, view)
            // Detach before the engine goes, as the Presentation did.
            view.detachFromFlutterEngine()
        }
        finish()
        BottomScreenEngine.release()
    }

    override fun onDestroy() {
        Log.i(TAG, "onDestroy")
        flutterView?.let { view ->
            main?.onBottomScreenClosing(this, view)
            view.detachFromFlutterEngine()
        }
        flutterView = null
        if (current?.get() === this) current = null
        super.onDestroy()
    }
}

/**
 * Window flags for one of the two screens. The window showing the main UI is
 * plain focusable. The one showing the secondary UI is too, so that a key that
 * reaches its display always has a window to go to (it forwards it to the main
 * UI); only while a game or app covers the main UI's screen is it made not
 * focusable, so a tap on it cannot take the gamepad away from that game.
 * FLAG_ALT_FOCUSABLE_IM, paired with FLAG_NOT_FOCUSABLE, keeps the window
 * below an IME that firmware pins to this display (AYN Thor
 * `ime_show_on_second`); a plain focusable window already stays below it.
 */
internal fun focusFlagsFor(showsMainUi: Boolean, mainUiCovered: Boolean): Int =
    if (!showsMainUi && mainUiCovered) {
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM
    } else {
        0
    }

/**
 * The secondary UI's Flutter engine (the `subDisplay` entrypoint), shared by
 * [SecondaryDisplayActivity] instances and kept across their recreation. Runs
 * in the same [io.flutter.embedding.engine.FlutterEngineGroup] the sub_screen
 * plugin set up, as the Presentation's engine did, so the shared state works
 * the same.
 */
object BottomScreenEngine {
    private const val TAG = "BottomScreenEngine"
    private const val APPS_CHANNEL = "com.neogamelab.neostation/secondary_apps"

    private var engine: FlutterEngine? = null
    private var appsChannel: MethodChannel? = null

    val current: FlutterEngine?
        get() = engine

    fun obtain(activity: Activity): FlutterEngine {
        engine?.let { return it }
        FlutterEngineHelper.init(activity.applicationContext)
        val group = FlutterEngineGroupCache.getInstance().get(FlutterEngineHelper.ENGINE_GROUP_ID)!!
        val entry = DartEntrypoint(
            FlutterInjector.instance().flutterLoader().findAppBundlePath(),
            "subDisplay"
        )
        val created = group.createAndRunEngine(activity.applicationContext, entry)
        engine = created
        appsChannel = MethodChannel(created.dartExecutor.binaryMessenger, APPS_CHANNEL).apply {
            setMethodCallHandler { call, result ->
                val main = MainActivity.instance
                if (main == null) {
                    result.error("UNAVAILABLE", "NeoStation is not running on the main screen", null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "getInstalledApps" ->
                        main.getInstalledApps(call.argument<Boolean>("includeSystemApps") ?: false, result)
                    "getAppIcon" -> {
                        val pkg = call.argument<String>("packageName")
                        if (pkg != null) main.getAppIcon(pkg, result)
                        else result.error("INVALID_ARGUMENTS", "Package name is required", null)
                    }
                    "launchAppOnSecondary" -> {
                        val pkg = call.argument<String>("packageName")
                        if (pkg != null) main.launchPackageOnSecondaryDisplay(pkg, result)
                        else result.error("INVALID_ARGUMENTS", "Package name is required", null)
                    }
                    "isDisplayOn" -> result.success(isDisplayOn())
                    else -> result.notImplemented()
                }
            }
        }
        Log.i(TAG, "engine started")
        return created
    }

    /** Live power state of the bottom display. Fails open, as the Presentation did. */
    private fun isDisplayOn(): Boolean {
        return try {
            val id = SecondaryDisplayActivity.instance?.displayId ?: return true
            val dm = MainActivity.instance?.getSystemService(android.content.Context.DISPLAY_SERVICE)
                as? android.hardware.display.DisplayManager ?: return true
            dm.getDisplay(id)?.state?.let { it == Display.STATE_ON } ?: true
        } catch (e: Exception) {
            true
        }
    }

    /** Pushes a device screen on/off edge to the secondary UI (see SecondaryAppsPresentation). */
    fun notifyScreenState(on: Boolean) {
        try {
            appsChannel?.invokeMethod(if (on) "onDeviceScreenOn" else "onDeviceScreenOff", null)
        } catch (e: Exception) {
            Log.e(TAG, "notifyScreenState failed: ${e.message}")
        }
    }

    fun release() {
        appsChannel?.setMethodCallHandler(null)
        appsChannel = null
        try {
            engine?.lifecycleChannel?.appIsDetached()
            engine?.destroy()
        } catch (e: Exception) {
            Log.w(TAG, "release failed: ${e.message}")
        }
        engine = null
    }
}
