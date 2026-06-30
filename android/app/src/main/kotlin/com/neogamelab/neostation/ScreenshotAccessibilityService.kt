package com.neogamelab.neostation

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.view.accessibility.AccessibilityEvent

/**
 * Minimal accessibility service whose only job is to fire a system screenshot
 * on request (the genuine OS screenshot of the main display, saved to the
 * gallery). It is triggered from [MainActivity] via a static reference rather
 * than reacting to accessibility events.
 */
class ScreenshotAccessibilityService : AccessibilityService() {

    companion object {
        @Volatile
        private var instance: ScreenshotAccessibilityService? = null

        /** True when the service is connected and able to take a screenshot. */
        val isConnected: Boolean
            get() = instance != null

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
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        super.onDestroy()
        instance = null
    }

    // Unused: this service neither observes events nor handles interrupts.
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    override fun onInterrupt() {}
}
