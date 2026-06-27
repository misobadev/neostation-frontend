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
import androidx.core.content.FileProvider

class MainActivity: MultiDisplayFlutterActivity(), GamepadsCompatibleActivity {
    private val CHANNEL = "com.neogamelab.neostation/game"
    private val LAUNCHER_CHANNEL = "com.neogamelab.neostation/launcher"
    var keyListener: ((KeyEvent) -> Boolean)? = null
    var motionListener: ((MotionEvent) -> Boolean)? = null
    private var isGameActive = false // Flag para saber si hay un juego activo
    private var gamepadBlockTimeout: Handler? = null // Timeout para desbloquear automáticamente
    private var methodChannel: MethodChannel? = null // Canal para comunicación con Flutter
    private var launcherMethodChannel: MethodChannel? = null // Canal para launcher
    private var secondaryDisplayChannel: MethodChannel? = null // Canal para pantalla secundaria
    private var gameLaunchTimestamp: Long = 0 // Timestamp del lanzamiento del juego
    private var displayListener: android.hardware.display.DisplayManager.DisplayListener? = null

    // Usar directorio por defecto para cores; no verificar existencia por permisos
    private fun getDefaultLibretroDirectory(retroArchPackage: String): String {
        return "/data/user/0/$retroArchPackage/cores/"
    }

    override fun getSubScreenEntryPoint(): String {
        return "subDisplay"
    }

    override fun createSubScreenPresentation(display: Display): FlutterPresentation? {
        return null
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
        super.onCreate(savedInstanceState)

        // Disable focus highlight for the entire activity
        window.setDecorFitsSystemWindows(false)
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
    }

    override fun onDestroy() {
        super.onDestroy()
        displayListener?.let {
            val dm = getSystemService(android.content.Context.DISPLAY_SERVICE) as android.hardware.display.DisplayManager
            dm.unregisterDisplayListener(it)
        }
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
                    result.success(isGameActive)
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
                "openAllFilesAccessSettings" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        try {
                            val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                            intent.data = Uri.parse("package:${packageName}")
                            intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            // Fallback to general manage all files access
                            val intent = Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                            intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            startActivity(intent)
                            result.success(true)
                        }
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
                "getSafFileSize" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString != null) {
                        getSafFileSize(uriString, result)
                    } else {
                        result.error("INVALID_ARGUMENTS", "URI is required", null)
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
                "installApk" -> {
                    val filePath = call.argument<String>("filePath")
                    if (filePath != null) {
                        installApk(filePath, result)
                    } else {
                        result.error("INVALID_ARGUMENTS", "File path is required", null)
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

    private fun setGamepadBlockInternal(block: Boolean, autoUnlockDelay: Long = 30000) {
        isGameActive = block
        if (block && autoUnlockDelay > 0) {
            gamepadBlockTimeout?.removeCallbacksAndMessages(null)
            gamepadBlockTimeout = Handler(Looper.getMainLooper()).apply {
                postDelayed(Runnable {
                    if (isGameActive) setGamepadBlockInternal(false, 0)
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
        if (isGameActive) return true
        val handled = motionListener?.invoke(motionEvent) ?: false
        return if (handled) true else super.dispatchGenericMotionEvent(motionEvent)
    }

    override fun dispatchKeyEvent(keyEvent: KeyEvent): Boolean {
        // BLOQUEAR COMPLETAMENTE el botón BACK (tanto del sistema como del gamepad)
        if (keyEvent.keyCode == KeyEvent.KEYCODE_BACK) {
            return true // Consumir completamente, no pasar a ningún lado
        }
        
        if (isGameActive) return true
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

    private fun getInstalledApps(includeSystemApps: Boolean, result: MethodChannel.Result) {
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
                    
                    var firstInstallTime: Long = 0
                    var versionName = ""
                    try {
                        val pInfo = pm.getPackageInfo(packageName, 0)
                        firstInstallTime = pInfo.firstInstallTime
                        versionName = pInfo.versionName ?: ""
                    } catch (e: Exception) { }

                    apps.add(mapOf(
                        "name" to label,
                        "package" to packageName,
                        "isSystemApp" to isSystemApp,
                        "isGame" to isGame,
                        "firstInstallTime" to firstInstallTime,
                        "version" to versionName,
                        "description" to "Android Application ($versionName)"
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
                // Block gamepad for a short duration to prevent accidental inputs on return
                setGamepadBlockInternal(true, 2000) 
                
                startActivity(intent)
                result.success(true)
            } else {
                result.error("LAUNCH_FAILED", "Could not find launch intent for package", null)
            }
        } catch (e: Exception) {
            result.error("LAUNCH_FAILED", e.message, null)
        }
    }

    private fun getAppIcon(packageName: String, result: MethodChannel.Result) {
        Thread {
            try {
                val iconDrawable = packageManager.getApplicationIcon(packageName)
                val bitmap = if (iconDrawable is BitmapDrawable) {
                    iconDrawable.bitmap
                } else {
                    val bitmap = android.graphics.Bitmap.createBitmap(
                        iconDrawable.intrinsicWidth,
                        iconDrawable.intrinsicHeight,
                        android.graphics.Bitmap.Config.ARGB_8888
                    )
                    val canvas = android.graphics.Canvas(bitmap)
                    iconDrawable.setBounds(0, 0, canvas.width, canvas.height)
                    iconDrawable.draw(canvas)
                    bitmap
                }

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
}
