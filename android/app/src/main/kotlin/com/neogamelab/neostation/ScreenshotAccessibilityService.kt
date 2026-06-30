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

        // --- Dock app-close watch ---
        @Volatile
        private var watchedPackage: String? = null
        @Volatile
        private var watchedDisplayId: Int = -1
        @Volatile
        private var onWatchedAppClosed: (() -> Unit)? = null

        /**
         * Starts watching [displayId] for the dismissal of [packageName] (a
         * dock-launched app). When the display returns to its launcher/home,
         * [onClosed] is invoked once. No-op if the service isn't connected.
         */
        fun startWatch(packageName: String, displayId: Int, onClosed: () -> Unit) {
            watchedPackage = packageName
            watchedDisplayId = displayId
            onWatchedAppClosed = onClosed
        }

        /** Cancels any in-progress app-close watch. */
        fun stopWatch() {
            watchedPackage = null
            watchedDisplayId = -1
            onWatchedAppClosed = null
        }

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
            // Restore only when the display has gone back to its home/launcher
            // (the back-out case), not when a transient dialog appears over the
            // app.
            if (top != watched && isHomePackage(top)) {
                val cb = onWatchedAppClosed
                stopWatch()
                cb?.invoke()
            }
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
