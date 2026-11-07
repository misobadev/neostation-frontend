package com.hcoderlee.subscreen.sub_screen

import android.content.Context
import android.content.Context.DISPLAY_SERVICE
import android.hardware.display.DisplayManager
import android.hardware.display.DisplayManager.DisplayListener
import android.view.Display

object MultiDisplayHandler {
    var hasInit = false
    private lateinit var displayManager: DisplayManager
    private var subScreenLauncher: ISubScreenLauncher? = null
    private var subDisplayId: Int? = null

    private val subDisplay
        get() = displayManager.displays.firstOrNull { !it.isDefault() }

    private val displayListener = object : DisplayListener {
        override fun onDisplayAdded(displayId: Int) {
            val display = displayManager.getDisplay(displayId)
            if (display != null &&
                !display.isDefault() &&
                subDisplayId == null &&
                displayManager.displays.size > 1
            ) {
                subDisplayId = displayId
                subScreenLauncher?.launchSubScreen(display)
                SubScreenPlugin.multiDisplayCallback.onDisplayAdded(display)
            }
        }

        override fun onDisplayChanged(displayId: Int) {
            val display = displayManager.getDisplay(displayId)
            if (displayId == subDisplayId && display != null) {
                SubScreenPlugin.multiDisplayCallback.onDisplayChange(display)
            }
        }

        override fun onDisplayRemoved(displayId: Int) {
            if (displayId == subDisplayId) {
                subScreenLauncher?.removeSubScreen(displayId)
                SubScreenPlugin.multiDisplayCallback.onDisplayRemoved(displayId)
                subDisplayId = null
            }
        }
    }

    val displays: Array<Display> get() = displayManager.displays

    fun init(context: Context) {
        if (hasInit) {
            return
        }
        hasInit = true

        displayManager = context.getSystemService(DISPLAY_SERVICE) as DisplayManager
        displayManager.registerDisplayListener(displayListener, null)
        subDisplayId = subDisplay?.displayId

    }

    fun setSubScreenLauncher(launcher: ISubScreenLauncher) {
        subScreenLauncher = launcher
        subDisplay?.let { display ->
            subScreenLauncher?.launchSubScreen(display)
        }
    }

    fun dispose() {
        displayManager.unregisterDisplayListener(displayListener)
    }
}

interface ISubScreenLauncher {
    fun launchSubScreen(display: Display)
    fun removeSubScreen(displayId: Int)
}

fun Display.isDefault() = displayId == Display.DEFAULT_DISPLAY
