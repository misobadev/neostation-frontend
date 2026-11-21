package com.neogamelab.neostation

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.os.Build
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityWindowInfo

/**
 * Accessibility service with two jobs:
 *  1. Fire a system screenshot on request (the genuine OS screenshot of the main
 *     display), triggered from [MainActivity] via the static reference below.
 *  2. Watch window changes so the secondary "Now Playing" panel can be restored
 *     the instant a dock-launched app is dismissed (back press) on the bottom
 *     display — Android gives normal apps no other signal for this.
 */
class ScreenshotAccessibilityService : AccessibilityService() {

    companion object {
        @Volatile
        private var instance: ScreenshotAccessibilityService? = null

        /** True when the service is connected and able to take a screenshot. */
        val isConnected: Boolean
            get() = instance != null

        /**
         * Invoked when the service connects (the user just enabled it). Lets the
         * app re-push accessibility state to the secondary display while a game
         * is running — the main engine is backgrounded then, so it can't observe
         * the grant via its own lifecycle.
         */
        @Volatile
        var onConnected: (() -> Unit)? = null

        // --- Dock app-close watch ---
        @Volatile
        private var watchedPackage: String? = null
        @Volatile
        private var watchedDisplayId: Int = -1
        @Volatile
        private var onWatchedAppClosed: (() -> Unit)? = null

        /**
         * Whether the watched app has been seen on top of the watched display
         * since the watch started. Until it has, "the display shows its home
         * screen" means the app hasn't drawn yet, not that it was closed.
         */
        @Volatile
        private var watchedAppSeen = false

        /**
         * Starts watching [displayId] for the dismissal of [packageName] (a
         * dock-launched app). When the display returns to its launcher/home
         * *after the app has actually appeared*, [onClosed] is invoked once.
         *
         * Returns false, arming nothing, when the watch cannot work: the service
         * isn't connected (user hasn't granted it), or the OS can't report
         * per-display windows (pre-R). Arming anyway would leave the caller
         * waiting for events that never come.
         */
        fun startWatch(packageName: String, displayId: Int, onClosed: () -> Unit): Boolean {
            if (instance == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
            watchedPackage = packageName
            watchedDisplayId = displayId
            watchedAppSeen = false
            onWatchedAppClosed = onClosed
            return true
        }

        /** Cancels any in-progress app-close watch. */
        fun stopWatch() {
            watchedPackage = null
            watchedDisplayId = -1
            watchedAppSeen = false
            onWatchedAppClosed = null
        }

        /** Whether a dock-app close watch is currently armed. */
        val isWatching: Boolean
            get() = watchedPackage != null

        /**
         * Whether the watch has seen the launched app take the display. False
         * while a launch is still in flight — the caller uses it to decide
         * whether a launch silently failed and the panel should come back.
         */
        val hasSeenWatchedApp: Boolean
            get() = watchedAppSeen

        /**
         * Performs a system screenshot via the global action. Returns false when
         * the service is not connected (user hasn't granted access).
         */
        fun takeScreenshot(): Boolean {
            val service = instance ?: return false
            return service.performGlobalAction(GLOBAL_ACTION_TAKE_SCREENSHOT)
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        onConnected?.invoke()
    }

    override fun onUnbind(intent: Intent?): Boolean {
        instance = null
        stopWatch()
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        super.onDestroy()
        instance = null
        stopWatch()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val watched = watchedPackage ?: return
        val displayId = watchedDisplayId
        if (displayId < 0) return
        try {
            val top = topAppPackageOnDisplay(displayId) ?: return
            // Phase 1: wait for the app to actually take the display. Hiding the
            // Now Playing panel is itself a window change, and the window it
            // uncovers is the display's own launcher — which looks exactly like
            // the back-out case below. Restoring on that would drop the panel
            // straight back on top of the app we just launched (it flashes and
            // is gone). Anything that is not the home screen means the launch
            // landed: the app itself, its splash, or a permission dialog.
            if (top == watched || !isHomePackage(top)) {
                watchedAppSeen = true
                return
            }
            if (!watchedAppSeen) return
            // Phase 2: the app was up and the display is back at its
            // home/launcher, so the user dismissed it. Restore the panel.
            val cb = onWatchedAppClosed
            stopWatch()
            cb?.invoke()
        } catch (e: Exception) {
            // Window introspection is best-effort; ignore transient failures.
        }
    }

    /** Package of the topmost application window on [displayId], or null. */
    private fun topAppPackageOnDisplay(displayId: Int): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        val list = windowsOnAllDisplays.get(displayId) ?: return null
        val top = list
            .filter { it.type == AccessibilityWindowInfo.TYPE_APPLICATION }
            .maxByOrNull { it.layer }
            ?: return null
        return top.root?.packageName?.toString()
    }

    /** Whether [pkg] is a home/launcher (covers the device's secondary launcher). */
    private fun isHomePackage(pkg: String): Boolean {
        val homeIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        val homePkg = packageManager.resolveActivity(homeIntent, 0)?.activityInfo?.packageName
        return pkg == homePkg || pkg.contains("launcher", ignoreCase = true)
    }

    override fun onInterrupt() {}
}
