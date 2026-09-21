package com.neogamelab.neostation

import android.hardware.input.InputManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.view.InputDevice
import android.view.KeyEvent
import android.os.Environment
import android.view.MotionEvent
import android.view.View
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.widget.Toast
import android.content.pm.PackageManager
import android.provider.Settings
import androidx.core.view.WindowCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.flame_engine.gamepads_android.GamepadsCompatibleActivity
import android.os.Looper
import java.lang.Runnable
import android.content.pm.ApplicationInfo
import java.io.File
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import java.io.ByteArrayOutputStream
import android.view.Display
import com.hcoderlee.subscreen.sub_screen.MultiDisplayFlutterActivity
import com.hcoderlee.subscreen.sub_screen.FlutterPresentation
import com.hcoderlee.subscreen.sub_screen.SharedStateManager
import androidx.core.content.FileProvider

class MainActivity: MultiDisplayFlutterActivity(), GamepadsCompatibleActivity {
    private val CHANNEL = "com.neogamelab.neostation/game"
    // Max size the dock/picker renders an app icon at; icons are rasterized to
    // this (in px) before encoding so we don't ship/decode full-res drawables.
    private val ICON_TARGET_DP = 56f
    private val LAUNCHER_CHANNEL = "com.neogamelab.neostation/launcher"
    // How long a dock-launched app gets to reach the bottom display before the
    // Now Playing panel comes back. Generous: a cold app start on this hardware
    // can take seconds, and coming back early is the bug this guards against.
    private val DOCK_LAUNCH_TIMEOUT_MS = 10_000L
    var keyListener: ((KeyEvent) -> Boolean)? = null
    var motionListener: ((MotionEvent) -> Boolean)? = null
    // A launched game still owns the foreground: set when Flutter starts a
    // session and cleared only when the user actually comes back (onResume) or
    // Flutter ends the session. Drives the session bookkeeping below — it must
    // NOT expire on its own, or a session outlives the flag that describes it.
    private var isGameActive = false
    // Gamepad input is swallowed so a stray press during the handoff to the
    // emulator can't leak into the UI behind it. Unlike [isGameActive] this is
    // deliberately short-lived and self-expiring, so a launch that never hands
    // off can't strand the pad.
    private var gamepadBlocked = false
    private var gamepadBlockTimeout: Handler? = null // Timeout para desbloquear automáticamente
    private var methodChannel: MethodChannel? = null // Canal para comunicación con Flutter
    private var launcherMethodChannel: MethodChannel? = null // Canal para launcher
    private var secondaryDisplayChannel: MethodChannel? = null // Canal para pantalla secundaria
    private var gameLaunchTimestamp: Long = 0 // Timestamp del lanzamiento del juego
    private var displayListener: android.hardware.display.DisplayManager.DisplayListener? = null
    // Bridges the device's real screen on/off state to the secondary engine, which
    // never receives Android lifecycle callbacks, so its live SESSION timer can
    // freeze while the device sleeps instead of counting phantom play time.
    private var screenStateReceiver: android.content.BroadcastReceiver? = null
    // True while the Now Playing presentation is hidden to reveal a dock-launched
    // app on the secondary display; restored when that app is dismissed.
    private var presentationHiddenForApp = false
    // Brings the panel back if a dock launch never puts its app on the bottom
    // display (a silently failed launch), so the panel can't stay hidden. One
    // handler instance: removeCallbacks only matches the handler that posted.
    private val dockLaunchHandler = Handler(Looper.getMainLooper())
    private var dockLaunchWatchdog: Runnable? = null

    // Usar directorio por defecto para cores; no verificar existencia por permisos
    private fun getDefaultLibretroDirectory(retroArchPackage: String): String {
        return "/data/user/0/$retroArchPackage/cores/"
    }

    override fun getSubScreenEntryPoint(): String {
        return "subDisplay"
    }

    override fun createSubScreenPresentation(display: Display): FlutterPresentation? {
        // Custom presentation that registers a secondary-engine-only MethodChannel
        // so the bottom-screen app dock can list/launch Android apps directly
        // (the secondary engine can't reach the main "/game" channel).
        return SecondaryAppsPresentation(this, display, getSubScreenEntryPoint())
    }

    override fun onLaunchSubScreen(display: Display) {
        if (isSecondaryDisplayHiddenInDb()) {
            // The sub_screen package may have already auto-created and shown the
            // presentation when a display reconnects. Actively close it here to
            // enforce the user's persisted preference.
            onCloseSubScreen()
            return
        }
        super.onLaunchSubScreen(display)
    }

    private fun getUserDataDir(): File {
        val prefs = getSharedPreferences("FlutterSharedPreferences", android.content.Context.MODE_PRIVATE)
        val customPath = prefs.getString("flutter.custom_user_data_path", null)
        return if (!customPath.isNullOrEmpty()) {
            File(customPath)
        } else {
            File(getExternalFilesDir(null), "user-data")
        }
    }

    private fun isSecondaryDisplayHiddenInDb(): Boolean {
        return try {
            val dbPath = File(getUserDataDir(), "data.sqlite").absolutePath
            val dbFile = File(dbPath)
            if (!dbFile.exists()) return false

            val db = android.database.sqlite.SQLiteDatabase.openDatabase(dbPath, null, android.database.sqlite.SQLiteDatabase.OPEN_READONLY)
            val cursor = db.rawQuery("SELECT hide_bottom_screen FROM user_config WHERE id = 1", null)
            var hidden = false
            if (cursor.moveToFirst()) {
                hidden = cursor.getInt(0) == 1
            }
            cursor.close()
            db.close()
            hidden
        } catch (e: Exception) {
            false
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // The secondary engine can survive a main-engine restart (cached engine
        // group), so its retained shared state may still say a game is "now
        // playing" from before the quit. Clear it before super.onCreate launches
        // the sub screen, so the stale Now Playing panel never renders.
        clearStaleSecondaryNowPlaying()
        super.onCreate(savedInstanceState)

        // Keep Android's soft-input resize contract intact.  With decor fitting
        // disabled, some handheld firmwares (including the AYN Odin 3) overlay
        // the IME on Flutter instead of reducing its viewport, leaving focused
        // metadata fields behind the keyboard despite `adjustResize` in the
        // manifest. System bars remain hidden below, so this does not change
        // the immersive presentation.
        WindowCompat.setDecorFitsSystemWindows(window, true)
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
            window.insetsController?.let { controller ->
                controller.hide(android.view.WindowInsets.Type.systemBars())
                controller.systemBarsBehavior = android.view.WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_FULLSCREEN
            )
        }

        registerScreenStateReceiver()
    }

    /// Listens for the device screen turning on/off and mirrors it into the
    /// secondary display's shared state as [deviceScreenOn]. A play session runs
    /// the game in a separate app, so this Activity is paused the whole time and
    /// its lifecycle can't tell "playing" from "sleeping" — only the screen state
    /// can, and it's the signal the secondary engine's SESSION timer needs.
    private fun registerScreenStateReceiver() {
        if (screenStateReceiver != null) return
        val receiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(context: android.content.Context?, intent: android.content.Intent?) {
                when (intent?.action) {
                    android.content.Intent.ACTION_SCREEN_OFF -> {
                        pushDeviceScreenOn(false)
                        notifySecondaryScreenState(false)
                        notifyFlutterScreenState(false)
                    }
                    android.content.Intent.ACTION_SCREEN_ON -> {
                        pushDeviceScreenOn(true)
                        notifySecondaryScreenState(true)
                        notifyFlutterScreenState(true)
                    }
                }
            }
        }
        val filter = android.content.IntentFilter().apply {
            addAction(android.content.Intent.ACTION_SCREEN_ON)
            addAction(android.content.Intent.ACTION_SCREEN_OFF)
        }
        registerReceiver(receiver, filter)
        screenStateReceiver = receiver
    }

    /// Merges the screen-on flag into the retained secondary display state,
    /// preserving every other field (same read-modify-write pattern as
    /// [clearStaleSecondaryNowPlaying]).
    private fun pushDeviceScreenOn(on: Boolean) {
        try {
            val type = "SecondaryDisplayState"
            val current = SharedStateManager.getState(type)?.toMutableMap() ?: return
            if (current["deviceScreenOn"] == on) return
            current["deviceScreenOn"] = on
            SharedStateManager.updateState(type, current)
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "pushDeviceScreenOn: ${e.message}")
        }
    }

    /// Delivers the screen on/off edge straight to the secondary engine, on its
    /// own channel. [pushDeviceScreenOn] mirrors the same fact into the shared
    /// state, but that transport ships whole snapshots between two engines with
    /// no ordering guarantee: a snapshot another producer built moments before
    /// the screen went off can land after this write and resurrect
    /// `deviceScreenOn: true`, leaving the bottom screen convinced the device is
    /// awake — which is how a preview video's audio kept playing with the lid
    /// shut. This edge cannot be clobbered, so the secondary engine treats it as
    /// the authority and only ever plays when BOTH agree the screen is on.
    private fun notifySecondaryScreenState(on: Boolean) {
        try {
            (subScreenPresentation as? SecondaryAppsPresentation)?.notifyScreenState(on)
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "notifySecondaryScreenState: ${e.message}")
        }
    }

    // As a HOME launcher, this Activity is NOT paused when the device screen
    // turns off, so Flutter never sees AppLifecycleState.paused on lock. Bridge
    // the raw screen on/off state to Dart so it can release the shared audio
    // engine while locked (its output device otherwise keeps the SoC awake and
    // drains the battery). Independent of pushDeviceScreenOn(), which no-ops on
    // single-screen devices.
    private fun notifyFlutterScreenState(on: Boolean) {
        runOnUiThread {
            try {
                methodChannel?.invokeMethod(
                    if (on) "onDeviceScreenOn" else "onDeviceScreenOff",
                    null
                )
            } catch (e: Exception) {
                android.util.Log.e("MainActivity", "notifyFlutterScreenState: ${e.message}")
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        // The watch callback and the watchdog both capture this activity; a
        // stale one would try to restore a presentation that died with it.
        ScreenshotAccessibilityService.stopWatch()
        dockLaunchWatchdog?.let { dockLaunchHandler.removeCallbacks(it) }
        dockLaunchWatchdog = null
        displayListener?.let {
            val dm = getSystemService(android.content.Context.DISPLAY_SERVICE) as android.hardware.display.DisplayManager
            dm.unregisterDisplayListener(it)
        }
        screenStateReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (e: IllegalArgumentException) {
                // Already unregistered; ignore.
            }
        }
        screenStateReceiver = null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler {
            call, result ->
            when (call.method) {
                "launchGenericIntent" -> {
                    val packageName = call.argument<String>("package")
                    val activityName = call.argument<String>("activity")
                    val action = call.argument<String>("action")
                    val category = call.argument<String>("category")
                    val data = call.argument<String>("data")
                    val type = call.argument<String>("type")
                    val extras = call.argument<List<Map<String, Any>>>("extras")
                    val activityFlags = call.argument<List<String>>("activity_flags") ?: emptyList()
                    val keepSafUri = call.argument<Boolean>("keep_saf_uri") ?: false

                    if (packageName != null) {
                        launchGenericIntent(packageName, activityName, action, category, data, type, extras, activityFlags, keepSafUri, result)
                    } else {
                        result.error("INVALID_ARGUMENTS", "Package name is required", null)
                    }
                }
                "launchGame" -> {
                    result.error("DEPRECATED", "Use launchGenericIntent instead", null)
                }
                "setGamepadBlock" -> {
                    val block = call.argument<Boolean>("block") ?: false
                    setGamepadBlock(block, result)
                }
                "getGamepadBlockStatus" -> {
                    // Reports the pad block, as the name says — not whether a
                    // game session is open (the two now expire independently).
                    result.success(gamepadBlocked)
                }
                "getGameLaunchTimestamp" -> {
                    result.success(gameLaunchTimestamp)
                }

                "isPackageInstalled" -> {
                    val packageName = call.argument<String>("packageName")
                    if (packageName != null) {
                        isPackageInstalled(packageName, result)
                    } else {
                        result.error("INVALID_ARGUMENTS", "Package name is required", null)
                    }
                }

                "isCoreInstalled" -> {
                    val packageName = call.argument<String>("packageName")
                    val coreFilename = call.argument<String>("coreFilename")
                    if (packageName != null && coreFilename != null) {
                        isCoreInstalled(packageName, coreFilename, result)
                    } else {
                        result.error("INVALID_ARGUMENTS", "packageName and coreFilename are required", null)
                    }
                }

                "getInstalledApps" -> {
                    val includeSystemApps = call.argument<Boolean>("includeSystemApps") ?: false
                    getInstalledApps(includeSystemApps, result)
                }
                "launchPackage" -> {
                    val packageName = call.argument<String>("packageName")
                    if (packageName != null) {
                        launchPackage(packageName, result)
                    } else {
                        result.error("INVALID_ARGUMENTS", "Package name is required", null)
                    }
                }
                "getAppIcon" -> {
                    val packageName = call.argument<String>("packageName")
                    if (packageName != null) {
                        getAppIcon(packageName, result)
                    } else {
                        result.error("INVALID_ARGUMENTS", "Package name is required", null)
                    }
                }
                "isTelevision" -> {
                    val uiModeManager = getSystemService(android.content.Context.UI_MODE_SERVICE) as android.app.UiModeManager
                    result.success(uiModeManager.currentModeType == android.content.res.Configuration.UI_MODE_TYPE_TELEVISION)
                }
                "getExternalStorageVolumes" -> {
                    getExternalStorageVolumes(result)
                }
                "openSafDirectoryPicker" -> {
                    openSafDirectoryPicker(result)
                }
                "hasPermission" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString != null) {
                        hasSafPermission(uriString, result)
                    } else {
                        result.error("INVALID_ARGUMENTS", "URI is required", null)
                    }
                }
                "openAllFilesAccessSettings" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        // Narrowest to broadest. The general All-Files list used
                        // to be the last resort but was itself launched outside
                        // any try/catch, so a ROM shipping neither All-Files
                        // activity threw out of the method channel and left the
                        // caller with no route to the grant. App details is a
                        // poorer landing spot but always resolves.
                        // skipAppPage drops the per-app page when Dart has
                        // already seen it come back without showing.
                        val skipAppPage = call.argument<Boolean>("skipAppPage") == true
                        val intents = listOfNotNull(
                            if (skipAppPage) null else
                                Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                                    .setData(Uri.parse("package:${packageName}")),
                            Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION),
                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                                .setData(Uri.parse("package:${packageName}"))
                        )
                        var opened = false
                        for (intent in intents) {
                            try {
                                intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                                startActivity(intent)
                                opened = true
                                break
                            } catch (e: Exception) {
                                android.util.Log.w(
                                    "MainActivity",
                                    "Cannot open ${intent.action}: ${e.message}"
                                )
                            }
                        }
                        if (!opened) {
                            android.util.Log.e(
                                "MainActivity",
                                "No activity could handle any All-Files settings intent"
                            )
                        }
                        result.success(opened)
                    } else {
                        result.success(false)
                    }
                }
                "listSafDirectory" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString != null) {
                        listSafDirectory(uriString, result)
                    } else {
                        result.error("INVALID_ARGUMENTS", "URI is required", null)
                    }
                }
                "fastWalkSafTree" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString != null) {
                        fastWalkSafTree(
                            uriString,
                            call.argument<Boolean>("recursive") ?: true,
                            call.argument<List<String>>("extensions") ?: emptyList(),
                            call.argument<Boolean>("ignoreHiddenFiles") ?: true,
                            result
                        )
                    } else {
                        result.error("INVALID_ARGUMENTS", "URI is required", null)
                    }
                }
                "createSafDirectory" -> {
                    val uriString = call.argument<String>("uri")
                    val name = call.argument<String>("name")
                    if (uriString != null && name != null) {
                        createSafDirectory(uriString, name, result)
                    } else {
                        result.error("INVALID_ARGUMENTS", "URI and name are required", null)
                    }
                }
                "moveSafFile" -> {
                    val sourceUri = call.argument<String>("sourceUri")
                    val targetUri = call.argument<String>("targetUri")
                    val name = call.argument<String>("name")
                    if (sourceUri != null && targetUri != null && name != null) {
                        moveSafFile(sourceUri, targetUri, name, result)
                    } else {
                        result.error("INVALID_ARGUMENTS", "Source, target, and name are required", null)
                    }
                }
                "writeSafFile" -> {
                    val uriString = call.argument<String>("uri")
                    val name = call.argument<String>("name")
                    val contents = call.argument<ByteArray>("contents")
                    if (uriString != null && name != null && contents != null) {
                        writeSafFile(uriString, name, contents, result)
                    } else {
                        result.error("INVALID_ARGUMENTS", "URI, name, and contents are required", null)
                    }
                }
                "readSafFileRange" -> {
                    val uriString = call.argument<String>("uri")
                    val offset = call.argument<Number>("offset")?.toLong() ?: 0L
                    val length = call.argument<Int>("length") ?: 0
                    if (uriString != null) {
                        readSafFileRange(uriString, offset, length, result)
                    } else {
                        result.error("INVALID_ARGUMENTS", "URI is required", null)
                    }
                }
                "readSafFile" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString != null) {
                        readSafFile(uriString, result)
                    } else {
                        result.error("INVALID_ARGUMENTS", "URI is required", null)
                    }
                }
                "openSafFileDescriptor" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString != null) {
                        openSafFileDescriptor(uriString, result)
                    } else {
                        result.error("INVALID_ARGUMENTS", "URI is required", null)
                    }
                }
                "getSafFileSize" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString != null) {
                        getSafFileSize(uriString, result)
                    } else {
                        result.error("INVALID_ARGUMENTS", "URI is required", null)
                    }
                }
                "getFreeSpace" -> {
                    val path = call.argument<String>("path")
                    if (path != null) {
                        getFreeSpace(path, result)
                    } else {
                        result.error("INVALID_ARGUMENTS", "Path is required", null)
                    }
                }
                "findEmulatorDocumentProvider" -> {
                    val packageName = call.argument<String>("packageName")
                    if (packageName != null) {
                        findEmulatorDocumentProvider(packageName, result)
                    } else {
                        result.error("INVALID_ARGUMENTS", "Package name is required", null)
                    }
                }
                "mirrorEmulatorNand" -> {
                    val packageName = call.argument<String>("packageName")
                    val emulatorName = call.argument<String>("emulatorName")
                    if (packageName != null && emulatorName != null) {
                        mirrorEmulatorNand(packageName, emulatorName, result)
                    } else {
                        result.error("INVALID_ARGUMENTS", "Package name and emulator name are required", null)
                    }
                }
                "startSecondaryDisplay" -> {
                    result.success(true)
                }
                "isScreenshotAccessEnabled" -> {
                    result.success(isScreenshotAccessEnabled())
                }
                "openScreenshotAccessSettings" -> {
                    openScreenshotAccessSettings()
                    result.success(true)
                }
                "takeSystemScreenshot" -> {
                    if (!isScreenshotAccessEnabled()) {
                        result.success(false)
                    } else {
                        result.success(ScreenshotAccessibilityService.takeScreenshot())
                    }
                }
                "installApk" -> {
                    val filePath = call.argument<String>("filePath")
                    if (filePath != null) {
                        installApk(filePath, result)
                    } else {
                        result.error("INVALID_ARGUMENTS", "File path is required", null)
                    }
                }
                "shareFile" -> {
                    val filePath = call.argument<String>("filePath")
                    val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
                    val title = call.argument<String>("title")
                    if (filePath != null) {
                        shareFile(filePath, mimeType, title, result)
                    } else {
                        result.error("INVALID_ARGUMENTS", "File path is required", null)
                    }
                }
                "deleteSafFile" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString != null) {
                        deleteSafFile(uriString, result)
                    } else {
                        result.error("INVALID_ARGUMENTS", "URI is required", null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // Secondary display channel
        secondaryDisplayChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.neogamelab.neostation/secondary_display")
        secondaryDisplayChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "setSecondaryDisplayVisible" -> {
                    val visible = call.argument<Boolean>("visible") ?: true
                    setSecondaryDisplayVisible(visible)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // When the accessibility service connects (user just enabled it), notify
        // the main engine so it re-pushes the screenshot/return state to the
        // secondary display — even while a game keeps the main engine
        // backgrounded. Hop to the UI thread: onServiceConnected runs off it.
        ScreenshotAccessibilityService.onConnected = {
            runOnUiThread {
                secondaryDisplayChannel?.invokeMethod("onAccessibilityConnected", null)
            }
        }

        // Launcher channel
        launcherMethodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LAUNCHER_CHANNEL)
        launcherMethodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "isDefaultLauncher" -> {
                    result.success(isDefaultLauncher())
                }
                "openDefaultAppsSettings" -> {
                    openDefaultAppsSettings()
                    result.success(true)
                }
                "openLauncherSettings" -> {
                    openLauncherSettings(result)
                }
                "openSystemSettings" -> {
                    openSystemSettings()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // Register display listener to notify Flutter when secondary display connects/disconnects
        displayListener = object : android.hardware.display.DisplayManager.DisplayListener {
            override fun onDisplayAdded(displayId: Int) {
                val dm = getSystemService(android.content.Context.DISPLAY_SERVICE) as android.hardware.display.DisplayManager
                val display = dm.getDisplay(displayId)
                if (display != null && displayId != Display.DEFAULT_DISPLAY && !isSecondaryDisplayHiddenInDb()) {
                    Handler(Looper.getMainLooper()).post {
                        secondaryDisplayChannel?.invokeMethod("onSecondaryDisplayConnected", null)
                    }
                }
            }

            override fun onDisplayRemoved(displayId: Int) {
                if (displayId != Display.DEFAULT_DISPLAY) {
                    Handler(Looper.getMainLooper()).post {
                        secondaryDisplayChannel?.invokeMethod("onSecondaryDisplayDisconnected", null)
                    }
                }
            }

            override fun onDisplayChanged(displayId: Int) {
                // No action needed for display changes
            }
        }
        val dm = getSystemService(android.content.Context.DISPLAY_SERVICE) as android.hardware.display.DisplayManager
        dm.registerDisplayListener(displayListener!!, Handler(Looper.getMainLooper()))
    }

    private fun setSecondaryDisplayVisible(visible: Boolean) {
        if (visible) {
            // A presentation that was dismissed behind our back (its engine is
            // already destroyed) still sits in subScreenPresentation, and a
            // non-null reference would block the recreate below — leaving the
            // bottom screen dead until the whole app is restarted. Anything
            // that is no longer showing, and isn't merely hidden to reveal a
            // dock-launched app, is dead: drop it so the branch below rebuilds.
            if (subScreenPresentation?.isShowing == false && !presentationHiddenForApp) {
                onCloseSubScreen()
            }
            if (subScreenPresentation == null) {
                val dm = getSystemService(android.content.Context.DISPLAY_SERVICE) as android.hardware.display.DisplayManager
                val displays = dm.displays
                val secondaryDisplay = displays.firstOrNull { it.displayId != android.view.Display.DEFAULT_DISPLAY }
                if (secondaryDisplay != null) {
                    try {                        val presentation = createSubScreenPresentation(secondaryDisplay) ?: FlutterPresentation(
                            this,
                            secondaryDisplay,
                            getSubScreenEntryPoint()
                        )
                        subScreenPresentation = presentation
                        presentation.show()
                        
                        onLaunchSubScreen(secondaryDisplay)

                    } catch (e: Exception) {
                        android.util.Log.e("MainActivity", "Error showing subscreen: ${e.message}")
                    }
                }
            }
        } else {
            onCloseSubScreen()
        }
    }

    /**
     * Clears the in-game flags in the retained secondary-display shared state so
     * a Now Playing panel left over from a quit-mid-game session doesn't render
     * when the main engine restarts. No-op on a cold start (no retained state).
     */
    private fun clearStaleSecondaryNowPlaying() {
        try {
            val type = "SecondaryDisplayState"
            val current = SharedStateManager.getState(type)?.toMutableMap() ?: return
            current["nowPlayingActive"] = false
            current["showAchievementPanel"] = false
            SharedStateManager.updateState(type, current)
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "clearStaleSecondaryNowPlaying: ${e.message}")
        }
    }

    /** True when the user has enabled our screenshot accessibility service. */
    private fun isScreenshotAccessEnabled(): Boolean {
        // A connected service is the most reliable signal; fall back to the
        // settings list in case the static reference isn't bound yet.
        if (ScreenshotAccessibilityService.isConnected) return true
        val enabled = android.provider.Settings.Secure.getString(
            contentResolver,
            android.provider.Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false
        // Build the component via ComponentName so the class keeps its real
        // namespace (com.neogamelab.neostation.*) while the package picks up the
        // flavor's applicationId suffix (.dev/.featuretest). A hand-built
        // "$packageName/$packageName.Foo" string gets the class package wrong on
        // suffixed flavors and never matches.
        val component = android.content.ComponentName(
            this,
            ScreenshotAccessibilityService::class.java,
        ).flattenToString()
        return enabled.split(':').any { it.equals(component, ignoreCase = true) }
    }

    /**
     * Opens accessibility settings so the user can grant access. Deep-links
     * straight to NeoStation's own service page (ACTION_ACCESSIBILITY_DETAILS_SETTINGS)
     * so the user only has to flip one toggle + confirm, rather than hunting for
     * NeoStation in the full list. Falls back to the general list if the details
     * screen isn't available.
     */
    internal fun openScreenshotAccessSettings() {
        val component = android.content.ComponentName(
            this,
            ScreenshotAccessibilityService::class.java,
        ).flattenToString()

        // Details page (API 30+): lands directly on our service's toggle.
        try {
            // Literal action string ("android.settings.ACCESSIBILITY_DETAILS_SETTINGS")
            // rather than the Settings constant, which isn't exposed on all
            // compile SDKs.
            val intent = android.content.Intent(
                "android.settings.ACCESSIBILITY_DETAILS_SETTINGS"
            )
            // The Settings details screen reads the target component from these
            // fragment-arg extras.
            val args = android.os.Bundle().apply {
                putString(":settings:fragment_args_key", component)
            }
            intent.putExtra(":settings:fragment_args_key", component)
            intent.putExtra(":settings:show_fragment_args", args)
            intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            return
        } catch (e: Exception) {
            android.util.Log.w(
                "MainActivity",
                "Accessibility details screen unavailable, falling back: ${e.message}",
            )
        }

        // Fallback: the general accessibility list.
        try {
            val intent = android.content.Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS)
            intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Cannot open accessibility settings: ${e.message}")
        }
    }

    private fun isPackageInstalled(packageName: String, result: MethodChannel.Result) {
        try {
            // Try to get package info
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                packageManager.getPackageInfo(packageName, android.content.pm.PackageManager.PackageInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageInfo(packageName, 0)
            }
            
            result.success(true)
        } catch (e: android.content.pm.PackageManager.NameNotFoundException) {
            result.success(false)
        } catch (e: Exception) {
            result.success(false)
        }
    }

    /**
     * Determines whether a specific RetroArch libretro core (.so) is actually present,
     * as opposed to merely having the RetroArch app installed. RetroArch stores its
     * cores in its own private data dir ({dataDir}/cores/), which this app's sandbox
     * usually cannot read — so a plain File.exists() from here returns false even when
     * the core IS installed. We therefore return a TRI-STATE:
     *   true  = core file positively confirmed present
     *   false = core file positively confirmed absent (cores dir was readable, or root)
     *   null  = could not determine (dir unreadable and no root) → caller must fail OPEN
     * This lets the Ready badge stay accurate where we can tell, without hiding genuinely
     * installed cores on non-rooted devices. See issue #192.
     */
    private fun isCoreInstalled(retroArchPackage: String, coreFilename: String, result: MethodChannel.Result) {
        try {
            val coresDir = try {
                val appInfo = packageManager.getApplicationInfo(retroArchPackage, 0)
                "${appInfo.dataDir}/cores/"
            } catch (e: Exception) {
                "/data/user/0/$retroArchPackage/cores/"
            }
            // The DB stores core_filename as the bare base (e.g. "ppsspp"); the actual
            // Android core is "<base>_libretro_android.so". Probe both the reconstructed
            // name and the raw value in case a full filename was ever stored.
            val base = coreFilename
                .removeSuffix("_libretro_android.so")
                .removeSuffix("_libretro.so")
            val candidates = linkedSetOf(
                "${base}_libretro_android.so",
                coreFilename,
            )

            // 1. Direct filesystem check. Trustworthy only if we can actually read the
            //    cores directory (usually we can't — it's RetroArch's private 0700 dir).
            if (candidates.any { java.io.File(coresDir, it).exists() }) {
                result.success(true)
                return
            }
            val dir = java.io.File(coresDir)
            if (dir.exists() && dir.canRead()) {
                // Directory readable and none of the candidates were in it → absent.
                result.success(false)
                return
            }

            // 2. Directory unreadable from our sandbox (RetroArch's private 0700 dir).
            //    We deliberately do NOT escalate to `su` here — requesting root would
            //    pop a Superuser prompt on rooted devices at game-launch time. Report
            //    unknown (null) → the caller fails open (treats the core as installed),
            //    which matches non-rooted/production behavior.
            result.success(null)
        } catch (e: Exception) {
            result.success(null)
        }
    }

    private fun openLauncherSettings(result: MethodChannel.Result) {
        try {
            // Opción 1: Intentar abrir la configuración de apps predeterminadas
            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                // Android 7+ (API 24+): Abrir configuración de apps predeterminadas
                Intent(android.provider.Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS)
            } else {
                // Android 6 y anteriores: Abrir configuración de aplicaciones
                Intent(android.provider.Settings.ACTION_SETTINGS)
            }
            
            intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            println("Error opening launcher settings: ${e.message}")
            
            // Fallback: Intentar abrir configuración general
            try {
                val fallbackIntent = Intent(android.provider.Settings.ACTION_SETTINGS)
                fallbackIntent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                startActivity(fallbackIntent)
                result.success(true)
            } catch (fallbackException: Exception) {
                result.error("OPEN_FAILED", fallbackException.message, null)
            }
        }
    }

    private fun openSystemSettings() {
        try {
            val intent = Intent(android.provider.Settings.ACTION_SETTINGS)
            intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
            startActivity(intent)
        } catch (e: Exception) {
            println("Error opening system settings: ${e.message}")
        }
    }

    private fun launchGenericIntent(
        packageName: String,
        activityName: String?,
        action: String?,
        category: String?,
        data: String?,
        type: String?,
        extras: List<Map<String, Any>>?,
        activityFlags: List<String>,
        keepSafUri: Boolean,
        result: MethodChannel.Result
    ) {
        EmulatorLauncher.launchGenericIntent(
            context = this,
            packageName = packageName,
            activityName = activityName,
            action = action,
            category = category,
            data = data,
            type = type,
            extras = extras,
            activityFlags = activityFlags,
            keepSafUri = keepSafUri,
            result = result
        )
    }



    private fun setGamepadBlock(block: Boolean, result: MethodChannel.Result) {
        setGamepadBlockInternal(block)
        result.success(true)
    }

    /**
     * Blocks or releases gamepad input, and — for a real game launch
     * ([markGameActive]) — opens or closes the session the bookkeeping in
     * [onPause]/[onResume] hangs off.
     *
     * The two are separate on purpose. The pad block auto-expires after
     * [autoUnlockDelay] so a launch that never hands off to an emulator can't
     * leave the pad dead, but a session routinely outlasts that timeout by
     * hours — expiring both together left every session longer than the timeout
     * with no "game active" flag, so the return path below silently did
     * nothing (including never clearing [gameLaunchTimestamp], which then
     * inflated the next session's elapsed time).
     *
     * App launches that only want the pad quiet during the handoff — the dock
     * and [launchPackage] — pass `markGameActive = false`.
     */
    private fun setGamepadBlockInternal(
        block: Boolean,
        autoUnlockDelay: Long = 30000,
        markGameActive: Boolean = true
    ) {
        gamepadBlocked = block
        if (markGameActive) isGameActive = block
        if (block && autoUnlockDelay > 0) {
            gamepadBlockTimeout?.removeCallbacksAndMessages(null)
            gamepadBlockTimeout = Handler(Looper.getMainLooper()).apply {
                postDelayed(Runnable {
                    // Release the pad only: the game is still running, and the
                    // session ends when the user returns, not on a timer.
                    gamepadBlocked = false
                }, autoUnlockDelay)
            }
        } else {
            gamepadBlockTimeout?.removeCallbacksAndMessages(null)
            gamepadBlockTimeout = null
        }
    }

    override fun onPause() {
        super.onPause()
        // Cuando la app va a segundo plano (RetroArch se abre), registrar el timestamp si no existe
        if (isGameActive && gameLaunchTimestamp == 0L) {
            gameLaunchTimestamp = System.currentTimeMillis()
        }
    }

    override fun onResume() {
        super.onResume()

        // Bring back the Now Playing panel if it was hidden for a dock-launched
        // app. Only when no watch is armed: a dock app lives on the *other*
        // display, so this activity resuming says nothing about whether it was
        // closed — restoring here would drop the panel on top of an app the user
        // is still using. While the watch runs, it owns the restore.
        if (!ScreenshotAccessibilityService.isWatching) {
            restoreSecondaryAfterApp()
        }

        if (isGameActive) {
            // Calcular tiempo transcurrido desde el lanzamiento (si tenemos timestamp)
            var elapsedSeconds = 0
            if (gameLaunchTimestamp > 0L) {
                val currentTime = System.currentTimeMillis()
                elapsedSeconds = ((currentTime - gameLaunchTimestamp) / 1000).toInt()
            }
            
            // Notificar a Flutter que el juego terminó si estuvimos en segundo plano lo suficiente
            // (o si simplemente volvimos y el block estaba activo)
            if (elapsedSeconds >= 5 || gameLaunchTimestamp == 0L) {
                 methodChannel?.invokeMethod("onGameReturned", mapOf(
                    "elapsedSeconds" to elapsedSeconds
                ))
            }
            
            // SIEMPRE desbloquear gamepad al volver, para evitar quedar bloqueado
            setGamepadBlockInternal(false, 0)
            
            // Resetear timestamp
            gameLaunchTimestamp = 0
        }
    }

    // Gamepad event forwarding / blocking
    override fun dispatchGenericMotionEvent(motionEvent: MotionEvent): Boolean {
        if (gamepadBlocked) return true
        val handled = motionListener?.invoke(motionEvent) ?: false
        return if (handled) true else super.dispatchGenericMotionEvent(motionEvent)
    }

    override fun dispatchKeyEvent(keyEvent: KeyEvent): Boolean {
        // BLOQUEAR COMPLETAMENTE el botón BACK (tanto del sistema como del gamepad)
        if (keyEvent.keyCode == KeyEvent.KEYCODE_BACK) {
            return true // Consumir completamente, no pasar a ningún lado
        }

        if (gamepadBlocked) return true
        val handled = keyListener?.invoke(keyEvent) ?: false
        return if (handled) true else super.dispatchKeyEvent(keyEvent)
    }

    // Launcher methods
    private fun isDefaultLauncher(): Boolean {
        try {
            val intent = Intent(Intent.ACTION_MAIN)
            intent.addCategory(Intent.CATEGORY_HOME)
            val resolveInfo = packageManager.resolveActivity(intent, 0)
            val currentHomePackage = resolveInfo?.activityInfo?.packageName
            return currentHomePackage == packageName
        } catch (e: Exception) {
            println("Error checking default launcher: ${e.message}")
            return false
        }
    }

    private fun openDefaultAppsSettings() {
        try {
            val intent = Intent(android.provider.Settings.ACTION_HOME_SETTINGS)
            startActivity(intent)
        } catch (e: Exception) {
            // If HOME_SETTINGS is not available, try SETTINGS
            try {
                val intent = Intent(android.provider.Settings.ACTION_SETTINGS)
                startActivity(intent)
            } catch (e2: Exception) {
                println("Error opening settings: ${e2.message}")
            }
        }
    }

    override fun registerInputDeviceListener(
        listener: InputManager.InputDeviceListener,
        handler: Handler?
    ) {
        val inputManager = getSystemService(INPUT_SERVICE) as InputManager
        inputManager.registerInputDeviceListener(listener, null)
    }

    override fun registerKeyEventHandler(handler: (KeyEvent) -> Boolean) {
        keyListener = handler
    }

    override fun registerMotionEventHandler(handler: (MotionEvent) -> Boolean) {
        motionListener = handler
    }

    // BLOQUEAR COMPLETAMENTE el botón BACK del sistema
    override fun onBackPressed() {
        // NO hacer nada - bloquear completamente la navegación hacia atrás
        // Esto previene que el botón Back de consolas como Retroid Pocket
        // tenga cualquier efecto en la aplicación
    }

    // --- NEW ANDROID APPS/GAMES LOGIC (SCAN EVERYTHING) ---

    internal fun getInstalledApps(includeSystemApps: Boolean, result: MethodChannel.Result) {
        Thread {
            try {
                val pm = packageManager
                
                // Use queryIntentActivities to find ALL launchable apps (Main + Launcher)
                // This guarantees we see "everything" in the app drawer (Chrome, YouTube, etc.)
                val mainIntent = Intent(Intent.ACTION_MAIN, null)
                mainIntent.addCategory(Intent.CATEGORY_LAUNCHER)
                
                // Retrieve all activities that can be launched
                val resolveInfos = pm.queryIntentActivities(mainIntent, 0)
                
                val processedPackages = mutableSetOf<String>()
                val apps = mutableListOf<Map<String, Any>>()

                for (resolveInfo in resolveInfos) {
                    val activityInfo = resolveInfo.activityInfo
                    val packageName = activityInfo.packageName
                    
                    // Deduplicate
                    if (processedPackages.contains(packageName)) continue
                    processedPackages.add(packageName)

                    // Filter out our own app
                    if (packageName == this.packageName) continue

                    val appInfo = activityInfo.applicationInfo 
                    val isSystemApp = (appInfo.flags and ApplicationInfo.FLAG_SYSTEM) != 0
                    
                    // All Android apps are now treated the same
                    val isGame = false

                    val label = resolveInfo.loadLabel(pm).toString()

                    // Only name+package are consumed by the dock/picker on the
                    // Dart side, so we deliberately skip the extra per-app
                    // pm.getPackageInfo() round-trip that used to fetch
                    // firstInstallTime/versionName here — on a device with many
                    // installed apps that second PackageManager hit per app was
                    // the bulk of the "app drawer takes seconds to wake up" lag.
                    apps.add(mapOf(
                        "name" to label,
                        "package" to packageName,
                        "isSystemApp" to isSystemApp,
                        "isGame" to isGame
                    ))
                }
                
                // Sort by name
                apps.sortBy { (it["name"].toString()).lowercase() }
                
                runOnUiThread {
                    result.success(apps)
                }
            } catch (e: Exception) {
                runOnUiThread {
                    result.error("FETCH_FAILED", e.message, null)
                }
            }
        }.start()
    }






    private fun launchPackage(packageName: String, result: MethodChannel.Result) {
        try {
            val intent = packageManager.getLaunchIntentForPackage(packageName)
            if (intent != null) {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                // Block gamepad for a short duration to prevent accidental inputs on return.
                // Not a game session: the caller owns that state, so leave isGameActive alone.
                setGamepadBlockInternal(true, 2000, markGameActive = false)

                startActivity(intent)
                result.success(true)
            } else {
                result.error("LAUNCH_FAILED", "Could not find launch intent for package", null)
            }
        } catch (e: Exception) {
            result.error("LAUNCH_FAILED", e.message, null)
        }
    }

    /**
     * Launches [packageName] preferring the secondary (bottom) display, falling
     * back to the default display if the OS rejects the targeted launch. Used by
     * the bottom-screen app dock.
     */
    internal fun launchPackageOnSecondaryDisplay(packageName: String, result: MethodChannel.Result) {
        try {
            val intent = packageManager.getLaunchIntentForPackage(packageName)
            if (intent == null) {
                result.error("LAUNCH_FAILED", "Could not find launch intent for package", null)
                return
            }
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            // Block gamepad briefly to avoid accidental inputs on return. A dock
            // app is not a game session, so this must not set isGameActive.
            setGamepadBlockInternal(true, 2000, markGameActive = false)

            val dm = getSystemService(android.content.Context.DISPLAY_SERVICE) as android.hardware.display.DisplayManager
            val secondaryDisplay = dm.displays.firstOrNull { it.displayId != Display.DEFAULT_DISPLAY }

            if (secondaryDisplay != null) {
                try {
                    val options = android.app.ActivityOptions.makeBasic()
                        .setLaunchDisplayId(secondaryDisplay.displayId)
                    startActivity(intent, options.toBundle())
                    // The Now Playing presentation is a TYPE_PRESENTATION window
                    // that layers above normal activities, so it would hide the
                    // app we just launched on the same display. Hide it (keeping
                    // the engine + dock state alive) and restore it on resume.
                    hideSecondaryForApp(packageName, secondaryDisplay.displayId)
                    result.success(true)
                    return
                } catch (e: Exception) {
                    android.util.Log.w("MainActivity", "Secondary-display launch failed, falling back: ${e.message}")
                }
            }

            // Fallback: launch on the default (top) display.
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("LAUNCH_FAILED", e.message, null)
        }
    }

    /**
     * Hides the Now Playing presentation so a dock-launched app is visible, and
     * (if the accessibility service is granted) watches the secondary display so
     * Now Playing is restored the moment the app is dismissed.
     */
    private fun hideSecondaryForApp(packageName: String, displayId: Int) {
        try {
            subScreenPresentation?.let {
                if (it.isShowing) {
                    it.hide()
                    presentationHiddenForApp = true
                }
            }
            // Without the watch (service not granted, or pre-R) there is nothing
            // to tell us the app closed and the watchdog would just drop the
            // panel onto a running app after its timeout, so arm neither:
            // onResume then restores, as it did before the watch existed.
            val watching = ScreenshotAccessibilityService.startWatch(packageName, displayId) {
                Handler(Looper.getMainLooper()).post { restoreSecondaryAfterApp() }
            }
            if (watching) armDockLaunchWatchdog()
        } catch (e: Exception) {
            android.util.Log.w("MainActivity", "Hiding secondary for app failed: ${e.message}")
        }
    }

    /**
     * Safety net for a dock launch that never reaches the bottom display: the
     * watch only restores the panel once it has seen the app take the display,
     * so an app that never appears (a launch the system dropped) would otherwise
     * leave the bottom screen showing the device's own launcher for good.
     */
    private fun armDockLaunchWatchdog() {
        dockLaunchWatchdog?.let { dockLaunchHandler.removeCallbacks(it) }
        val watchdog = Runnable {
            dockLaunchWatchdog = null
            if (presentationHiddenForApp && !ScreenshotAccessibilityService.hasSeenWatchedApp) {
                android.util.Log.w("MainActivity", "Dock launch never reached the bottom display; restoring the panel")
                restoreSecondaryAfterApp()
            }
        }
        dockLaunchWatchdog = watchdog
        dockLaunchHandler.postDelayed(watchdog, DOCK_LAUNCH_TIMEOUT_MS)
    }

    /** Restores the Now Playing presentation hidden by a dock launch. */
    private fun restoreSecondaryAfterApp() {
        ScreenshotAccessibilityService.stopWatch()
        dockLaunchWatchdog?.let {
            dockLaunchHandler.removeCallbacks(it)
            dockLaunchWatchdog = null
        }
        if (!presentationHiddenForApp) return
        presentationHiddenForApp = false
        try {
            subScreenPresentation?.show()
        } catch (e: Exception) {
            android.util.Log.w("MainActivity", "Restoring secondary after app failed: ${e.message}")
        }
    }

    internal fun getAppIcon(packageName: String, result: MethodChannel.Result) {
        Thread {
            try {
                val iconDrawable = packageManager.getApplicationIcon(packageName)
                // The dock/picker never renders an icon larger than ~56dp, so
                // rasterize straight into a small target bitmap instead of
                // encoding the source drawable at its native resolution
                // (adaptive icons are often 192-432px). This shrinks both the
                // PNG encode here and the Image.memory decode on the Dart side,
                // which was making the dock feel sluggish while icons loaded.
                val targetPx = (ICON_TARGET_DP * resources.displayMetrics.density).toInt()
                val bitmap = android.graphics.Bitmap.createBitmap(
                    targetPx,
                    targetPx,
                    android.graphics.Bitmap.Config.ARGB_8888
                )
                val canvas = android.graphics.Canvas(bitmap)
                iconDrawable.setBounds(0, 0, targetPx, targetPx)
                iconDrawable.draw(canvas)

                val stream = ByteArrayOutputStream()
                bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, stream)
                val byteArray = stream.toByteArray()
                
                runOnUiThread {
                    result.success(byteArray)
                }
            } catch (e: Exception) {
                 runOnUiThread {
                    result.error("ICON_ERROR", e.message, null)
                }
            }
        }.start()
    }

    // --- SAF IMPLEMENTATION (Play Store Compliant) ---
    private var safResult: MethodChannel.Result? = null
    private val SAF_PICKER_REQUEST_CODE = 9999

    private fun openSafDirectoryPicker(result: MethodChannel.Result) {
        safResult = result
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            intent.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            intent.addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            startActivityForResult(intent, SAF_PICKER_REQUEST_CODE)
        } catch (e: Exception) {
            result.error("PICKER_FAILED", e.message, null)
            safResult = null
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == SAF_PICKER_REQUEST_CODE) {
            if (resultCode == android.app.Activity.RESULT_OK && data != null && data.data != null) {
                val uri = data.data!!
                try {
                    // Take persistable permission is CRITICAL for long-term access
                    val takeFlags: Int = Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    contentResolver.takePersistableUriPermission(uri, takeFlags)
                    
                    // VALIDATION: Verify we can actually list the folder contents
                    val docId = android.provider.DocumentsContract.getTreeDocumentId(uri)
                    val childrenUri = android.provider.DocumentsContract.buildChildDocumentsUriUsingTree(uri, docId)
                    
                    val cursor = contentResolver.query(
                        childrenUri,
                        arrayOf(android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                        null, null, null
                    )
                    
                    val canList = cursor != null && cursor.count >= 0
                    cursor?.close()
                    
                    if (!canList) {
                        println("SAF: Selected folder appears empty or inaccessible")
                    }
                    
                    safResult?.success(uri.toString())
                } catch (e: Exception) {
                    safResult?.error("PERMISSION_FAILED", "Failed to take persistable permission: ${e.message}", null)
                }
            } else {
                safResult?.success(null) // Cancelled
            }
            safResult = null
        }
    }

    /**
     * Walks a SAF tree with direct filesystem I/O instead of per-directory
     * DocumentsProvider queries, returning the same document URIs the SAF walk
     * would have produced.
     *
     * The SAF walk costs one `ContentResolver.query` per directory — a binder round
     * trip into ExternalStorageProvider that does the real directory read anyway.
     * Measured on a 98-directory / 9.3k-file library that is ~994 ms against ~266 ms
     * for the equivalent `java.io.File` walk. When the tree lives on primary external
     * storage and the app holds MANAGE_EXTERNAL_STORAGE, the provider buys nothing.
     *
     * URIs are built with [DocumentsContract.buildDocumentUriUsingTree] rather than
     * assembled by hand, so the strings are byte-identical to the SAF walk's. That
     * matters: `rom_path` is the identity of a ROM row, and re-encoding it even
     * slightly differently would orphan every row along with its favourite flag,
     * play time and per-game settings.
     *
     * Returns null — meaning "caller should use the SAF walk" — whenever the fast
     * path is not provably equivalent: non-primary volume (SD, USB OTG), permission
     * not held, the path not resolving to a readable directory, or any directory
     * failing to list mid-walk. It never reports a directory it could not read as
     * an empty one.
     */
    private fun fastWalkSafTree(
        uriString: String,
        recursive: Boolean,
        extensions: List<String>,
        ignoreHiddenFiles: Boolean,
        result: MethodChannel.Result
    ) {
        Thread {
            try {
                val uri = Uri.parse(uriString)

                // isExternalStorageManager() is API 30. minSdk is 24, and an
                // unguarded call throws NoSuchMethodError on anything older -- an
                // Error, not an Exception, so a `catch (Exception)` would miss it and
                // it would reach Android's default uncaught-exception handler, which
                // kills the whole process. Verified on a real API 28 device: removing
                // this clause and narrowing the catch below crashes the app on first
                // scan.
                // Below API 30 there is no manager permission to hold, so decline and
                // let the SAF walk run.
                val eligible = uri.authority == "com.android.externalstorage.documents" &&
                    android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R &&
                    android.os.Environment.isExternalStorageManager()
                if (!eligible) {
                    runOnUiThread { result.success(null) }
                    return@Thread
                }

                val docId = if (android.provider.DocumentsContract.isDocumentUri(this, uri)) {
                    android.provider.DocumentsContract.getDocumentId(uri)
                } else {
                    android.provider.DocumentsContract.getTreeDocumentId(uri)
                }

                // Only the primary volume has a stable, derivable filesystem path.
                // "primary:emu/roms" -> "<external storage>/emu/roms"
                if (!docId.startsWith("primary:")) {
                    runOnUiThread { result.success(null) }
                    return@Thread
                }
                val relativeRoot = docId.removePrefix("primary:")
                val root = java.io.File(
                    android.os.Environment.getExternalStorageDirectory(),
                    relativeRoot
                )
                if (!root.isDirectory || !root.canRead()) {
                    runOnUiThread { result.success(null) }
                    return@Thread
                }

                val exts = extensions.map { it.lowercase() }.toSet()
                val out = mutableListOf<Map<String, Any>>()

                // Iterative walk; the directory stack holds (file, documentId) pairs so
                // each child's document id is built by simple concatenation.
                val stack = ArrayDeque<Pair<java.io.File, String>>()
                stack.addLast(root to docId)

                // File.isDirectory follows symlinks, so a symlinked cycle would loop
                // here forever. The DocumentsProvider never exposed one; direct I/O
                // can. Canonical paths already-descended are skipped.
                val visited = HashSet<String>()

                while (stack.isNotEmpty()) {
                    val (dir, dirDocId) = stack.removeLast()
                    if (!visited.add(dir.canonicalPath)) continue
                    // listFiles() returns null on an I/O or permission failure,
                    // which at this level is indistinguishable from an empty
                    // directory. Skipping it would report every file it holds as
                    // deleted, so decline the whole walk instead and let the SAF
                    // walk -- which reaches the tree through the
                    // DocumentsProvider rather than direct I/O -- answer. This is
                    // the contract the Dart side documents: null means "cannot
                    // serve this", never "no files".
                    val children = dir.listFiles()
                    if (children == null) {
                        android.util.Log.w(
                            "MainActivity",
                            "fastWalkSafTree: listFiles() failed for ${dir.path}, falling back"
                        )
                        runOnUiThread { result.success(null) }
                        return@Thread
                    }
                    // Sorted so the result order does not depend on filesystem order.
                    children.sortBy { it.name }

                    for (child in children) {
                        val name = child.name
                        if (ignoreHiddenFiles && name.trim().startsWith(".")) continue

                        val childDocId = "$dirDocId/$name"
                        if (child.isDirectory) {
                            if (recursive) stack.addLast(child to childDocId)
                            continue
                        }

                        if (exts.isNotEmpty()) {
                            // `dot > 0`, not `>= 0`: package:path treats a leading dot as
                            // part of the basename, so ".nes" has no extension there. With
                            // >= 0 the two walks would disagree on dotfiles whenever
                            // hidden files are shown.
                            val dot = name.lastIndexOf('.')
                            val ext = if (dot > 0) name.substring(dot + 1).lowercase() else ""
                            if (!exts.contains(ext)) continue
                        }

                        val fileUri = android.provider.DocumentsContract
                            .buildDocumentUriUsingTree(uri, childDocId)
                        out.add(
                            mapOf(
                                "uri" to fileUri.toString(),
                                "name" to name,
                                "size" to child.length()
                            )
                        )
                    }
                }

                runOnUiThread { result.success(out) }
            } catch (t: Throwable) {
                // Throwable, not Exception: an Error escaping this thread reaches
                // Android's default uncaught-exception handler, which kills the process
                // rather than leaving `result` merely uncompleted. Measured on API 28:
                // this catch alone recovers the pre-API-30
                // NoSuchMethodError and the scan finishes normally, so it is a genuine
                // second line of defence behind the SDK_INT guard, not decoration.
                // Falling back also avoids reporting an empty system, which would be
                // read as "every ROM for it was deleted".
                android.util.Log.w("MainActivity", "fastWalkSafTree failed, falling back: $t")
                runOnUiThread { result.success(null) }
            }
        }.start()
    }

    private fun listSafDirectory(uriString: String, result: MethodChannel.Result) {
        Thread {
            try {
                // Parsing URI and building doc children URI
                val uri = Uri.parse(uriString)
                
                // CRITICAL FIX: Use getDocumentId for document URIs (subdirectories)
                // getTreeDocumentId only works for tree roots, not subdirectories
                val docId = if (android.provider.DocumentsContract.isDocumentUri(this, uri)) {
                    android.provider.DocumentsContract.getDocumentId(uri)
                } else {
                    android.provider.DocumentsContract.getTreeDocumentId(uri)
                }
                
                val childrenUri = android.provider.DocumentsContract.buildChildDocumentsUriUsingTree(uri, docId)
                
                val children = mutableListOf<Map<String, Any>>()
                
                val cursor = contentResolver.query(
                    childrenUri,
                    arrayOf(
                        android.provider.DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                        android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                        android.provider.DocumentsContract.Document.COLUMN_MIME_TYPE,
                        android.provider.DocumentsContract.Document.COLUMN_SIZE,
                        android.provider.DocumentsContract.Document.COLUMN_LAST_MODIFIED
                    ),
                    null,
                    null,
                    null
                )
                
                cursor?.use {
                    while (it.moveToNext()) {
                        val id = it.getString(0)
                        val name = it.getString(1)
                        val mimeType = it.getString(2)
                        val size = it.getLong(3)
                        val lastModified = it.getLong(4)
                        val isDir = mimeType == android.provider.DocumentsContract.Document.MIME_TYPE_DIR
                        
                        // Build individual URI for the file (needed for opening)
                        val fileUri = android.provider.DocumentsContract.buildDocumentUriUsingTree(uri, id)
                        
                        children.add(mapOf(
                            "uri" to fileUri.toString(), // Fix: Dart expects "uri"
                            "path" to fileUri.toString(), // Keep "path" for backward compatibility
                            "name" to name,
                            "isDirectory" to isDir,
                            "size" to size,
                            "lastModified" to lastModified
                        ))
                    }
                }
                
                runOnUiThread {
                    result.success(children)
                }
                
            } catch (e: Exception) {
                runOnUiThread {
                    result.error("LIST_FAILED", e.message, null)
                }
            }
        }.start()
    }

    private fun hasSafPermission(uriString: String, result: MethodChannel.Result) {
        try {
            val uri = Uri.parse(uriString)
            val hasPermission = contentResolver.persistedUriPermissions.any { permission ->
                permission.uri == uri && permission.isReadPermission && permission.isWritePermission
            }
            result.success(hasPermission)
        } catch (e: Exception) {
            result.success(false)
        }
    }

    private fun deleteSafFile(uriString: String, result: MethodChannel.Result) {
        Thread {
            try {
                val uri = Uri.parse(uriString)

                // Determine the document ID: supports both tree URIs and document URIs
                val docId = if (android.provider.DocumentsContract.isDocumentUri(this, uri)) {
                    android.provider.DocumentsContract.getDocumentId(uri)
                } else {
                    android.provider.DocumentsContract.getTreeDocumentId(uri)
                }

                // Build the child document URI if needed
                val deleteUri = if (android.provider.DocumentsContract.isTreeUri(uri)) {
                    android.provider.DocumentsContract.buildDocumentUriUsingTree(uri, docId)
                } else {
                    uri
                }

                val deleted = android.provider.DocumentsContract.deleteDocument(contentResolver, deleteUri)
                runOnUiThread { result.success(deleted) }
            } catch (e: Exception) {
                android.util.Log.e("MainActivity", "deleteSafFile error: ${e.message}")
                runOnUiThread { result.error("DELETE_FAILED", e.message, null) }
            }
        }.start()
    }

    private fun safDocumentUri(uriString: String): Uri {
        val uri = Uri.parse(uriString)
        val documentId = if (android.provider.DocumentsContract.isDocumentUri(this, uri)) {
            android.provider.DocumentsContract.getDocumentId(uri)
        } else {
            android.provider.DocumentsContract.getTreeDocumentId(uri)
        }
        return if (android.provider.DocumentsContract.isTreeUri(uri)) {
            android.provider.DocumentsContract.buildDocumentUriUsingTree(uri, documentId)
        } else {
            uri
        }
    }

    private fun createSafDirectory(uriString: String, name: String, result: MethodChannel.Result) {
        Thread {
            try {
                val created = android.provider.DocumentsContract.createDocument(
                    contentResolver,
                    safDocumentUri(uriString),
                    android.provider.DocumentsContract.Document.MIME_TYPE_DIR,
                    name
                )
                runOnUiThread { result.success(created?.toString()) }
            } catch (e: Exception) {
                runOnUiThread { result.error("CREATE_DIRECTORY_FAILED", e.message, null) }
            }
        }.start()
    }

    private fun moveSafFile(
        sourceUriString: String,
        targetUriString: String,
        name: String,
        result: MethodChannel.Result
    ) {
        Thread {
            var created: Uri? = null
            try {
                val sourceUri = Uri.parse(sourceUriString)
                val targetUri = safDocumentUri(targetUriString)
                val createdFile = android.provider.DocumentsContract.createDocument(
                    contentResolver,
                    targetUri,
                    "application/octet-stream",
                    name
                ) ?: throw java.io.IOException("Could not create target file")
                created = createdFile

                contentResolver.openInputStream(sourceUri)?.use { input ->
                    contentResolver.openOutputStream(createdFile, "w")?.use { output ->
                        input.copyTo(output)
                    } ?: throw java.io.IOException("Could not open target file")
                } ?: throw java.io.IOException("Could not open source file")

                if (!android.provider.DocumentsContract.deleteDocument(contentResolver, sourceUri)) {
                    throw java.io.IOException("Could not remove source file")
                }
                created = null
                runOnUiThread { result.success(true) }
            } catch (e: Exception) {
                // A move is copy-then-delete for SAF. Remove only the file we
                // created if either step fails, so a retry cannot leave duplicates.
                created?.let { destinationUri ->
                    runCatching {
                        android.provider.DocumentsContract.deleteDocument(
                            contentResolver,
                            destinationUri
                        )
                    }
                }
                runOnUiThread { result.error("MOVE_FILE_FAILED", e.message, null) }
            }
        }.start()
    }

    private fun writeSafFile(
        uriString: String,
        name: String,
        contents: ByteArray,
        result: MethodChannel.Result
    ) {
        Thread {
            try {
                val parentUri = Uri.parse(uriString)
                val parentDocumentUri = safDocumentUri(uriString)
                val treeUri = if (android.provider.DocumentsContract.isTreeUri(parentUri)) {
                    parentUri
                } else {
                    android.provider.DocumentsContract.buildTreeDocumentUri(
                        parentUri.authority!!,
                        android.provider.DocumentsContract.getDocumentId(parentUri)
                    )
                }
                val parentId = android.provider.DocumentsContract.getDocumentId(parentDocumentUri)
                val childrenUri = android.provider.DocumentsContract.buildChildDocumentsUriUsingTree(
                    treeUri,
                    parentId
                )
                var fileUri: Uri? = null
                contentResolver.query(
                    childrenUri,
                    arrayOf(
                        android.provider.DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                        android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME
                    ),
                    null,
                    null,
                    null
                )?.use { cursor ->
                    while (cursor.moveToNext()) {
                        if (cursor.getString(1) == name) {
                            fileUri = android.provider.DocumentsContract.buildDocumentUriUsingTree(
                                treeUri,
                                cursor.getString(0)
                            )
                            break
                        }
                    }
                }
                if (fileUri == null) {
                    fileUri = android.provider.DocumentsContract.createDocument(
                        contentResolver,
                        parentDocumentUri,
                        "audio/x-mpegurl",
                        name
                    )
                }
                val outputUri = fileUri ?: throw java.io.IOException("Could not create playlist")
                contentResolver.openOutputStream(outputUri, "w")?.use { output ->
                    output.write(contents)
                } ?: throw java.io.IOException("Could not open playlist")
                runOnUiThread { result.success(true) }
            } catch (e: Exception) {
                runOnUiThread { result.error("WRITE_FILE_FAILED", e.message, null) }
            }
        }.start()
    }

    /**
     * Bytes still writable by this app on the volume holding [path], or null
     * when that can't be answered.
     *
     * Backs the RomM bulk sync's pre-flight check ("does this platform fit?").
     * usableSpace — rather than freeSpace — is the honest number: it accounts
     * for the reserve the OS keeps back, so it matches what a download can
     * actually claim.
     *
     * Returns null rather than 0 for an unknown or missing volume: the Dart
     * side treats null as "no opinion" and lets the sync proceed, and a 0
     * would read as a full disk and warn about a problem that isn't there.
     * The caller passes a path that exists (it walks up to the nearest
     * existing ancestor first), so 0 here really does mean "not on a volume
     * this app can see".
     */
    private fun getFreeSpace(path: String, result: MethodChannel.Result) {
        Thread {
            val bytes = try {
                java.io.File(path).usableSpace.takeIf { it > 0L }
            } catch (e: Exception) {
                android.util.Log.w("MainActivity", "Free space for $path unavailable: ${e.message}")
                null
            }
            runOnUiThread { result.success(bytes) }
        }.start()
    }

    private fun getSafFileSize(uriString: String, result: MethodChannel.Result) {
        Thread {
            try {
                val uri = Uri.parse(uriString)
                var size: Long = 0
                val cursor = contentResolver.query(
                    uri,
                    arrayOf(android.provider.DocumentsContract.Document.COLUMN_SIZE),
                    null, null, null
                )
                cursor?.use {
                    if (it.moveToFirst()) {
                        size = it.getLong(0)
                    }
                }
                runOnUiThread { result.success(size) }
            } catch (e: Exception) {
                runOnUiThread { result.error("SIZE_FAILED", e.message, null) }
            }
        }.start()
    }

    private fun readSafFileRange(uriString: String, offset: Long, length: Int, result: MethodChannel.Result) {
        Thread {
            try {
                val uri = Uri.parse(uriString)
                val pfd = contentResolver.openFileDescriptor(uri, "r")
                
                if (pfd == null) {
                    runOnUiThread { result.error("READ_FAILED", "Could not open file descriptor", null) }
                    return@Thread
                }

                pfd.use { descriptor ->
                    val fileDescriptor = descriptor.fileDescriptor
                    val inputStream = java.io.FileInputStream(fileDescriptor)
                    
                    inputStream.use { stream ->
                        // Skip to the offset
                        if (offset > 0) {
                            stream.skip(offset)
                        }

                        val buffer = ByteArray(length)
                        var totalRead = 0
                        while (totalRead < length) {
                            val read = stream.read(buffer, totalRead, length - totalRead)
                            if (read == -1) break
                            totalRead += read
                        }

                        // Adjust buffer if we read less than requested
                        val finalBuffer = if (totalRead < length) {
                            buffer.copyOf(totalRead)
                        } else {
                            buffer
                        }

                        runOnUiThread {
                            result.success(finalBuffer)
                        }
                    }
                }
            } catch (e: Exception) {
                runOnUiThread {
                    result.error("READ_FAILED", e.message, null)
                }
            }
        }.start()
    }

    /**
     * Opens a SAF document and detaches its file descriptor for native code.
     *
     * The CHD reader seeks all over a multi-gigabyte disc image, so going back
     * through this channel per read would cost thousands of round trips. The
     * descriptor is detached rather than closed here: whoever asked for it owns
     * it, and the native reader closes it when it closes the disc.
     */
    private fun openSafFileDescriptor(uriString: String, result: MethodChannel.Result) {
        Thread {
            try {
                val uri = Uri.parse(uriString)
                val pfd = contentResolver.openFileDescriptor(uri, "r")

                if (pfd == null) {
                    runOnUiThread { result.error("OPEN_FAILED", "Could not open file descriptor", null) }
                    return@Thread
                }

                val fd = pfd.detachFd()
                runOnUiThread { result.success(fd) }
            } catch (e: Exception) {
                runOnUiThread {
                    result.error("OPEN_FAILED", e.message, null)
                }
            }
        }.start()
    }

    private fun readSafFile(uriString: String, result: MethodChannel.Result) {
        Thread {
            try {
                val uri = Uri.parse(uriString)
                val pfd = contentResolver.openFileDescriptor(uri, "r")
                
                if (pfd == null) {
                    runOnUiThread { result.error("READ_FAILED", "Could not open file descriptor", null) }
                    return@Thread
                }

                pfd.use { descriptor ->
                    val fileDescriptor = descriptor.fileDescriptor
                    val inputStream = java.io.FileInputStream(fileDescriptor)
                    
                    inputStream.use { stream ->
                        val outputStream = java.io.ByteArrayOutputStream()
                        val buffer = ByteArray(8192)
                        var read: Int
                        while (stream.read(buffer).also { read = it } != -1) {
                            outputStream.write(buffer, 0, read)
                        }
                        
                        runOnUiThread {
                            result.success(outputStream.toByteArray())
                        }
                    }
                }
            } catch (e: Exception) {
                runOnUiThread {
                    result.error("READ_FAILED", e.message, null)
                }
            }
        }.start()
    }

    private fun findEmulatorDocumentProvider(packageName: String, result: MethodChannel.Result) {
        Thread {
            try {
                val pm = packageManager
                
                val packageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    pm.getPackageInfo(packageName, PackageManager.GET_PROVIDERS)
                } else {
                    @Suppress("DEPRECATION")
                    pm.getPackageInfo(packageName, PackageManager.GET_PROVIDERS)
                }
                
                val providers = packageInfo.providers ?: emptyArray()
                
                for (provider in providers) {
                    val authority = provider.authority ?: continue
                    
                    try {
                        val rootsUri = android.provider.DocumentsContract.buildRootsUri(authority)
                        val cursor = contentResolver.query(
                            rootsUri,
                            arrayOf(
                                android.provider.DocumentsContract.Root.COLUMN_ROOT_ID,
                                android.provider.DocumentsContract.Root.COLUMN_DOCUMENT_ID,
                                android.provider.DocumentsContract.Root.COLUMN_TITLE,
                                android.provider.DocumentsContract.Root.COLUMN_SUMMARY
                            ),
                            null, null, null
                        )
                        
                        cursor?.use {
                            while (it.moveToNext()) {
                                val rootId = it.getString(0)
                                val documentId = it.getString(1)
                                val title = it.getString(2)
                                val summary = it.getString(3)
                                
                                val treeUri = android.provider.DocumentsContract.buildTreeDocumentUri(authority, documentId)
                                
                                // Verify we can actually list children
                                val childrenUri = android.provider.DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, documentId)
                                val childCursor = contentResolver.query(
                                    childrenUri,
                                    arrayOf(android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                                    null, null, null
                                )
                                
                                val hasAccess = childCursor != null
                                childCursor?.close()
                                
                                if (hasAccess) {
                                    runOnUiThread {
                                        result.success(mapOf(
                                            "authority" to authority,
                                            "rootId" to rootId,
                                            "documentId" to documentId,
                                            "title" to title,
                                            "summary" to summary,
                                            "treeUri" to treeUri.toString()
                                        ))
                                    }
                                    return@Thread
                                }
                            }
                        }
                    } catch (e: Exception) {
                        continue
                    }
                }
                
                runOnUiThread {
                    result.success(null)
                }
            } catch (e: Exception) {
                runOnUiThread {
                    result.error("PROVIDER_ERROR", e.message, null)
                }
            }
        }.start()
    }

    private fun mirrorEmulatorNand(packageName: String, emulatorName: String, result: MethodChannel.Result) {
        Thread {
            try {
                val externalDir = getExternalFilesDir(null) ?: run {
                    runOnUiThread { result.success(null) }
                    return@Thread
                }
                val mirrorRoot = File(externalDir, "switch_mirrors/$emulatorName/nand")
                mirrorRoot.mkdirs()

                val normalPath = "/storage/emulated/0/Android/data/$packageName/files"
                val bypassPath = "/storage/emulated/0/Android/\u200bdata/$packageName/files"

                var sourceDir: File? = null

                // 1. Try normal path first
                val normalFile = File(normalPath)
                if (normalFile.exists() && normalFile.canRead()) {
                    sourceDir = normalFile
                }

                // 2. Try SAF ExternalStorageProvider trick (Android 11-12)
                if (sourceDir == null) {
                    try {
                        val treeUri = android.provider.DocumentsContract.buildTreeDocumentUri(
                            "com.android.externalstorage.documents",
                            "primary:Android/data/$packageName/files"
                        )
                        val docId = android.provider.DocumentsContract.getTreeDocumentId(treeUri)
                        val childrenUri = android.provider.DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, docId)
                        val cursor = contentResolver.query(
                            childrenUri,
                            arrayOf(android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                            null, null, null
                        )
                        if (cursor != null) {
                            cursor.close()
                            // If we can list, mirror via SAF
                            mirrorViaSaf(treeUri, mirrorRoot)
                            runOnUiThread { result.success(mirrorRoot.absolutePath) }
                            return@Thread
                        }
                    } catch (e: Exception) {
                        // SAF trick failed
                    }
                }

                // 3. Try zero-width bypass (Android 14+)
                if (sourceDir == null) {
                    try {
                        val bypassFile = File(bypassPath)
                        if (bypassFile.exists() && bypassFile.canRead()) {
                            sourceDir = bypassFile
                        }
                    } catch (e: Exception) {
                        // Bypass failed
                    }
                }

                if (sourceDir == null) {
                    runOnUiThread { result.success(null) }
                    return@Thread
                }

                // Mirror from filesystem source
                mirrorDirectory(sourceDir, mirrorRoot)
                runOnUiThread { result.success(mirrorRoot.absolutePath) }
            } catch (e: Exception) {
                runOnUiThread {
                    result.error("MIRROR_ERROR", e.message, null)
                }
            }
        }.start()
    }

    private fun mirrorDirectory(source: File, dest: File) {
        if (!source.exists()) return
        if (source.isDirectory) {
            dest.mkdirs()
            source.listFiles()?.forEach { child ->
                mirrorDirectory(child, File(dest, child.name))
            }
        } else {
            if (!dest.exists() || dest.length() != source.length()) {
                source.copyTo(dest, overwrite = true)
            }
            // Preserve timestamp
            try {
                dest.setLastModified(source.lastModified())
            } catch (_: Exception) {}
        }
    }

    private fun mirrorViaSaf(treeUri: android.net.Uri, destRoot: File) {
        val docId = android.provider.DocumentsContract.getTreeDocumentId(treeUri)
        mirrorSafRecursive(treeUri, docId, destRoot)
    }

    private fun mirrorSafRecursive(treeUri: android.net.Uri, documentId: String, destDir: File) {
        val childrenUri = android.provider.DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, documentId)
        val cursor = contentResolver.query(
            childrenUri,
            arrayOf(
                android.provider.DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                android.provider.DocumentsContract.Document.COLUMN_MIME_TYPE,
                android.provider.DocumentsContract.Document.COLUMN_SIZE
            ),
            null, null, null
        )
        
        cursor?.use {
            while (it.moveToNext()) {
                val id = it.getString(0)
                val name = it.getString(1)
                val mimeType = it.getString(2)
                val size = it.getLong(3)
                val isDir = mimeType == android.provider.DocumentsContract.Document.MIME_TYPE_DIR
                val destFile = File(destDir, name)
                
                if (isDir) {
                    destFile.mkdirs()
                    mirrorSafRecursive(treeUri, id, destFile)
                } else {
                    if (!destFile.exists() || destFile.length() != size) {
                        val fileUri = android.provider.DocumentsContract.buildDocumentUriUsingTree(treeUri, id)
                        contentResolver.openInputStream(fileUri)?.use { input ->
                            destFile.outputStream().use { output ->
                                input.copyTo(output)
                            }
                        }
                    }
                }
            }
        }
    }

    private fun getExternalStorageVolumes(result: MethodChannel.Result) {
        try {
            val volumes = mutableListOf<Map<String, Any>>()
            val storageManager = getSystemService(android.content.Context.STORAGE_SERVICE) as android.os.storage.StorageManager

            // getExternalFilesDirs returns one entry per available storage volume.
            val externalDirs = getExternalFilesDirs(null)

            for (dir in externalDirs) {
                if (dir == null) continue

                // Strip /Android/data/<package>/files to get volume root
                var rootPath = dir.absolutePath
                val androidIdx = rootPath.indexOf("/Android/data/")
                if (androidIdx >= 0) rootPath = rootPath.substring(0, androidIdx)

                var description = "External Storage"
                var isRemovable = true
                val isPrimary = rootPath.contains("/emulated/0") ||
                        rootPath == android.os.Environment.getExternalStorageDirectory()?.absolutePath

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    try {
                        val volume = storageManager.getStorageVolume(dir)
                        if (volume != null) {
                            description = volume.getDescription(this) ?: description
                            isRemovable = volume.isRemovable
                        }
                    } catch (_: Exception) {}
                }

                if (isPrimary) description = "Internal Storage"

                volumes.add(mapOf(
                    "path" to rootPath,
                    "description" to description,
                    "isInternal" to isPrimary,
                    "isRemovable" to isRemovable
                ))
            }

            result.success(volumes)
        } catch (e: Exception) {
            result.error("STORAGE_ERROR", e.message, null)
        }
    }

    private fun installApk(filePath: String, result: MethodChannel.Result) {
        val file = File(filePath)
        if (!file.exists()) {
            result.error("FILE_NOT_FOUND", "APK file not found at $filePath", null)
            return
        }

        // Check if we have permission to install packages (Android 8.0+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (!packageManager.canRequestPackageInstalls()) {
                try {
                    val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                    intent.data = Uri.parse("package:$packageName")
                    intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    startActivity(intent)
                    result.error("PERMISSION_DENIED", "Install unknown apps permission required", null)
                    return
                } catch (e: Exception) {
                    result.error("INTENT_ERROR", "Could not open install settings: ${e.message}", null)
                    return
                }
            }
        }

        try {
            val contentUri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                file
            )

            val intent = Intent(Intent.ACTION_VIEW)
            intent.setDataAndType(contentUri, "application/vnd.android.package-archive")
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("INSTALL_ERROR", "Failed to launch installer: ${e.message}", null)
        }
    }

    /// Opens the system share sheet with [filePath] attached, e.g. so a user
    /// can send their log zip straight to Discord. The file must sit under a
    /// path covered by file_provider_paths.xml (the cache dir is).
    private fun shareFile(filePath: String, mimeType: String, title: String?, result: MethodChannel.Result) {
        try {
            val file = File(filePath)
            if (!file.exists()) {
                result.error("FILE_NOT_FOUND", "File not found: $filePath", null)
                return
            }
            val contentUri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val send = Intent(Intent.ACTION_SEND).apply {
                type = mimeType
                putExtra(Intent.EXTRA_STREAM, contentUri)
                clipData = android.content.ClipData.newRawUri(file.name, contentUri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(send, title))
            result.success(true)
        } catch (e: Exception) {
            result.error("SHARE_ERROR", "Failed to share file: ${e.message}", null)
        }
    }
}
