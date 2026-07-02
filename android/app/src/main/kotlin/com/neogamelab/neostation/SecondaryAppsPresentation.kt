package com.neogamelab.neostation

import android.os.Bundle
import android.util.Log
import android.view.Display
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
 * the locked `sub_screen` dependency version.
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
        registerAppsChannel()
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
                    else -> result.notImplemented()
                }
            }
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
