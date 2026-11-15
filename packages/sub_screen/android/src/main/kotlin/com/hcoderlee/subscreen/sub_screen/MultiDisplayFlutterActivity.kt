package com.hcoderlee.subscreen.sub_screen

import android.app.Presentation
import android.os.Bundle
import android.util.Log
import android.view.Display
import android.view.View
import androidx.annotation.CallSuper
import io.flutter.embedding.android.FlutterActivity

open class MultiDisplayFlutterActivity : FlutterActivity() {

    companion object {
        private const val SUB_SCREEN_ENTRY_POINT = "subScreenEntry"
        private const val TAG = "MultiDisplay"
    }

    protected var subScreenPresentation: Presentation? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        FlutterEngineHelper.init(this)
        super.onCreate(savedInstanceState)
        MultiDisplayHandler.init(this)
        MultiDisplayHandler.setSubScreenLauncher(object : ISubScreenLauncher {
            override fun launchSubScreen(display: Display) {
                this@MultiDisplayFlutterActivity.launchSubScreen(display)
            }

            override fun removeSubScreen(displayId: Int) {
                onCloseSubScreen()
            }
        })
    }

    override fun setContentView(flutterView: View?) {
        super.setContentView(flutterView)
        // Make sure flutter view has focus at beginning, flutter framework will not transfer keyboard
        // event when flutter view is not focused
        flutterView?.requestFocus()
    }

    override fun getCachedEngineGroupId(): String? {
        return FlutterEngineHelper.ENGINE_GROUP_ID
    }

    /**
     * Return the entry point function name for the flutter engine of sub screen
     */
    protected open fun getSubScreenEntryPoint(): String? {
        return null
    }

    override fun onDestroy() {
        super.onDestroy()
        MultiDisplayHandler.dispose()
        onCloseSubScreen()
    }

    private fun launchSubScreen(display: Display) {
        try {
            subScreenPresentation = (createSubScreenPresentation(display) ?: FlutterPresentation(
                context,
                display,
                getSubScreenEntryPoint() ?: SUB_SCREEN_ENTRY_POINT
            )).apply {
                show()
            }
            onLaunchSubScreen(display)
        } catch (e: Exception) {
            Log.e(TAG, "Cannot launch sub screen: ", e)
        }
    }

    protected open fun onLaunchSubScreen(display: Display) {
    }

    @CallSuper
    protected open fun onCloseSubScreen() {
        subScreenPresentation?.dismiss()
        subScreenPresentation = null
    }

    protected open fun createSubScreenPresentation(display: Display): FlutterPresentation? {
        return null
    }
}