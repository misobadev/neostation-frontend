package com.neogamelab.neostation

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.provider.OpenableColumns
import io.flutter.plugin.common.MethodChannel
import java.io.File

object EmulatorLauncher {

    private const val ROM_IMPORT_DIR = "rom_import"
    private const val MAX_CACHE_AGE_MS = 7 * 24 * 60 * 60 * 1000L // 7 days
    private const val MAX_ROM_CACHE_SIZE_BYTES = 1024L * 1024L * 1024L // 1GB

    fun launchGenericIntent(
        context: Context,
        packageName: String,
        activityName: String?,
        action: String?,
        category: String?,
        data: String?,
        type: String?,
        extras: List<Map<String, Any>>?,
        activityFlags: List<String>,
        result: MethodChannel.Result
    ) {
        try {
            val intent = Intent()
            if (activityName != null) {
                intent.component = ComponentName(packageName, activityName)
            } else {
                intent.setPackage(packageName)
            }
            intent.action = action ?: Intent.ACTION_MAIN

            if (category != null) {
                intent.addCategory(category)
            } else if (action == null || action == Intent.ACTION_MAIN) {
                intent.addCategory(Intent.CATEGORY_LAUNCHER)
            }

            // Resolve neostation-* markers before building the intent. Markers are
            // injected by the Dart launcher when the JSON config uses {file.realpath}
            // or {file.fileuri} placeholders. All other values pass
            // through unchanged, so this step is a no-op for emulators that don't opt in.
            val resolvedData = data?.let { resolveMarkedValue(context, it) }
            val resolvedExtras: List<Map<String, Any>>? = extras?.map { extra ->
                val rawValue = extra["value"]?.toString() ?: return@map extra
                val resolved = resolveMarkedValue(context, rawValue)
                if (resolved == rawValue) extra
                else extra.toMutableMap().also { m -> m["value"] = resolved }
            }

            var uriData: Uri? = null
            if (resolvedData != null) {
                uriData = if (!resolvedData.contains("://") && resolvedData.startsWith("/")) {
                    Uri.parse("file://$resolvedData")
                } else {
                    Uri.parse(resolvedData)
                }
            }

            if (uriData != null && type != null) {
                intent.setDataAndType(uriData, type)
            } else if (uriData != null) {
                intent.data = uriData
            } else if (type != null) {
                intent.type = type
            }

            // FLAG_ACTIVITY_NEW_TASK is always required when launching from a non-Activity context.
            // All other flags come from the JSON config via --activity-* args.
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            activityFlags.forEach { flag -> flagStringToIntent(flag)?.let { intent.addFlags(it) } }

            // Set extras
            if (resolvedExtras != null) {
                for (extra in resolvedExtras) {
                    val key = extra["key"] as? String ?: continue
                    val value = extra["value"] ?: continue
                    val valueType = extra["type"] as? String ?: continue
                    val finalValue = value.toString()

                    // RetroArch-specific: LIBRETRO core path construction uses the package name
                    // to locate the correct cores directory. CONFIGFILE default is set below.
                    if (packageName.startsWith("com.retroarch") && key == "LIBRETRO" && !finalValue.startsWith("/")) {
                        val libretroDir = getDefaultLibretroDirectory(packageName)
                        val base = finalValue
                            .removeSuffix("_libretro_android.so")
                            .removeSuffix("_libretro.so")
                        intent.putExtra(key, "$libretroDir${base}_libretro_android.so")
                        continue
                    }

                    when (valueType) {
                        "string" -> intent.putExtra(key, finalValue)
                        "bool" -> intent.putExtra(key, finalValue.toBoolean())
                        "int" -> intent.putExtra(key, finalValue.toIntOrNull() ?: 0)
                        "long" -> intent.putExtra(key, finalValue.toLongOrNull() ?: 0L)
                        "float" -> intent.putExtra(key, finalValue.toFloatOrNull() ?: 0.0f)
                        "uri" -> intent.putExtra(key, Uri.parse(finalValue))
                        "string_array" -> intent.putExtra(
                            key, finalValue.split(",").map { it.trim() }.toTypedArray()
                        )
                    }
                }
            }

            // RetroArch: inject CONFIGFILE default if the JSON didn't supply one.
            // The path is package-specific (each RetroArch variant has its own data dir).
            if (packageName.startsWith("com.retroarch") && !intent.hasExtra("CONFIGFILE")) {
                intent.putExtra(
                    "CONFIGFILE",
                    "/storage/emulated/0/Android/data/$packageName/files/retroarch.cfg"
                )
            }

            // Generic SAF permission grant: any remaining content:// URI in data or extras
            // (i.e. values that were NOT resolved by a neostation-* marker) gets ClipData +
            // permissions so Android propagates the grant correctly before startActivity().
            val primaryContentUri: Uri? = when {
                uriData?.scheme == "content" -> uriData
                else -> resolvedExtras?.firstOrNull { extra ->
                    extra["value"]?.toString()?.startsWith("content://") == true
                }?.let { Uri.parse(it["value"].toString()) }
            }
            if (primaryContentUri != null) {
                // Explicit grantUriPermission is synchronous — the permission exists
                // before startActivity() is called. FLAG_GRANT_READ_URI_PERMISSION alone
                // is processed asynchronously by ActivityManager, so on first launch the
                // emulator can attempt to read the file before the grant arrives → fails.
                // Second launch works because the permission is already cached.
                try {
                    context.grantUriPermission(
                        packageName,
                        primaryContentUri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION
                    )
                } catch (_: Exception) { }

                intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                if (intent.clipData == null) {
                    intent.clipData = ClipData.newRawUri("ROM", primaryContentUri)
                }

                // Multi-file formats (.cue, .gdi, .m3u) reference sibling track files
                // (.bin, .iso, .img, .wav, etc.) that also need explicit URI permissions.
                // Without this, the emulator can open the cue/gdi but gets permission
                // denied when it tries to read the actual track data.
                val masterFileName = getFileNameFromUri(context, primaryContentUri) ?: ""
                val masterExt = masterFileName.substringAfterLast('.', "").lowercase()
                if (masterExt in setOf("cue", "gdi", "m3u") &&
                    android.provider.DocumentsContract.isDocumentUri(context, primaryContentUri) &&
                    android.provider.DocumentsContract.isTreeUri(primaryContentUri)) {
                    grantSiblingTrackPermissions(context, packageName, primaryContentUri)
                }
            }

            // StrictMode: allow file:// URIs in intent data for legacy emulators that need them
            try {
                val m = android.os.StrictMode::class.java.getMethod("disableDeathOnFileUriExposure")
                m.invoke(null)
            } catch (e: Exception) { }

            // Don't use resolveActivity — returns null on Android 11+ for valid apps due to
            // package visibility restrictions. Catch ActivityNotFoundException instead.
            context.startActivity(intent)
            result.success(true)
        } catch (e: ActivityNotFoundException) {
            result.error("ACTIVITY_NOT_FOUND", "Emulator not installed or activity missing: $packageName", null)
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", "Permission denied launching $packageName: ${e.message}", null)
        } catch (e: Exception) {
            e.printStackTrace()
            result.error("LAUNCH_FAILED", e.message, e.toString())
        }
    }

    // Resolves neostation-* markers injected by the Dart launcher for placeholders that
    // require Android SAF access at launch time. Unknown or plain values pass through.
    //
    //  neostation-realpath:<uri> → best-effort real filesystem path: resolves SAF
    //                              content:// directly; falls back to a local cache
    //                              copy for network/NAS providers (Round Sync, CIFS…)
    //                              that have no filesystem mapping.
    //  neostation-fileuri:<uri>  → same resolution as realpath, returned as file:// URI.
    private fun resolveMarkedValue(context: Context, value: String): String {
        return when {
            value.startsWith("neostation-realpath:") -> {
                val raw = value.removePrefix("neostation-realpath:")
                if (raw.startsWith("content://")) {
                    val uri = Uri.parse(raw)
                    resolveSafUriToPath(context, uri) ?: run {
                        val fileName = getFileNameFromUri(context, uri) ?: "rom"
                        cacheContentUriToFile(context, uri, fileName)?.absolutePath ?: raw
                    }
                } else raw
            }
            value.startsWith("neostation-fileuri:") -> {
                val raw = value.removePrefix("neostation-fileuri:")
                if (raw.startsWith("content://")) {
                    val uri = Uri.parse(raw)
                    val path = resolveSafUriToPath(context, uri) ?: run {
                        val fileName = getFileNameFromUri(context, uri) ?: "rom"
                        cacheContentUriToFile(context, uri, fileName)?.absolutePath
                    }
                    if (path != null) "file://$path" else raw
                } else if (raw.startsWith("file://")) raw
                else "file://$raw"
            }
            else -> value
        }
    }

    private fun flagStringToIntent(flag: String): Int? = when (flag) {
        "clear-task" -> Intent.FLAG_ACTIVITY_CLEAR_TASK
        "clear-top" -> Intent.FLAG_ACTIVITY_CLEAR_TOP
        "no-animation" -> Intent.FLAG_ACTIVITY_NO_ANIMATION
        "no-history" -> Intent.FLAG_ACTIVITY_NO_HISTORY
        "single-top" -> Intent.FLAG_ACTIVITY_SINGLE_TOP
        "reorder-to-front" -> Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
        "reset-task-if-needed" -> Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
        "brought-to-front" -> Intent.FLAG_ACTIVITY_BROUGHT_TO_FRONT
        else -> null
    }

    private fun resolveSafUriToPath(context: Context, uri: Uri): String? {
        try {
            if (isExternalStorageDocument(uri)) {
                var docId = android.provider.DocumentsContract.getDocumentId(uri)
                if (docId.contains("%3A") || docId.contains("%3a")) {
                    docId = Uri.decode(docId)
                }
                val split = docId.split(":").toTypedArray()
                if (split.size < 2) return null
                val type = split[0]
                val path = split[1]
                return if ("primary".equals(type, ignoreCase = true)) {
                    Environment.getExternalStorageDirectory().toString() + "/" + path
                } else {
                    "/storage/$type/$path"
                }
            }
        } catch (e: Exception) {
            println("Error resolving URI to path: $e")
        }
        return null
    }

    private fun getFileNameFromUri(context: Context, uri: Uri): String? {
        var result: String? = null
        if (uri.scheme == "content") {
            context.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null, null, null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) {
                        result = cursor.getString(idx)
                    }
                }
            }
        }
        if (result == null) {
            result = uri.lastPathSegment
        }
        return result
    }

    private fun cleanupOldCacheFiles(dir: File) {
        try {
            val cutoff = System.currentTimeMillis() - MAX_CACHE_AGE_MS
            dir.listFiles()?.forEach { file ->
                if (file.isFile && file.lastModified() < cutoff) {
                    file.delete()
                }
            }
        } catch (_: Exception) { }
    }

    private fun cacheContentUriToFile(context: Context, uri: Uri, fileName: String): File? {
        try {
            val cacheDir = context.externalCacheDir ?: context.cacheDir
            val importDir = File(cacheDir, ROM_IMPORT_DIR)
            if (!importDir.exists()) {
                importDir.mkdirs()
            }

            cleanupOldCacheFiles(importDir)

            val destFile = File(importDir, fileName)

            // Determine remote file size
            var remoteSize = -1L
            context.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.SIZE),
                null, null, null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (idx >= 0) {
                        remoteSize = cursor.getLong(idx)
                    }
                }
            }
            if (remoteSize <= 0) {
                context.contentResolver.query(
                    uri,
                    arrayOf(android.provider.DocumentsContract.Document.COLUMN_SIZE),
                    null, null, null
                )?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val idx = cursor.getColumnIndex(android.provider.DocumentsContract.Document.COLUMN_SIZE)
                        if (idx >= 0) {
                            remoteSize = cursor.getLong(idx)
                        }
                    }
                }
            }

            // Skip copy if we already have an up-to-date cached copy
            if (destFile.exists() && destFile.length() == remoteSize && remoteSize > 0) {
                println("Using cached ROM: ${destFile.absolutePath}")
                return destFile
            }

            // Guard against filling storage with huge files
            if (remoteSize > MAX_ROM_CACHE_SIZE_BYTES) {
                println("ROM too large to cache ($remoteSize bytes), skipping local copy.")
                return null
            }

            println("Caching ROM from SAF to local storage: ${destFile.absolutePath}")
            context.contentResolver.openInputStream(uri)?.use { input ->
                destFile.outputStream().use { output ->
                    input.copyTo(output)
                }
            }
            println("ROM cached successfully: ${destFile.absolutePath}")
            return destFile
        } catch (e: Exception) {
            println("Error caching content URI to file: $e")
            return null
        }
    }

    private fun getDefaultLibretroDirectory(retroArchPackage: String): String {
        return "/data/user/0/$retroArchPackage/cores/"
    }

    private fun isExternalStorageDocument(uri: Uri): Boolean {
        return "com.android.externalstorage.documents" == uri.authority
    }

    // Grants read permission for sibling track files belonging to the same disc image.
    // Matches: (1) any extension with the exact same base name, or (2) track files whose
    // name starts with the master base name (e.g. "Game Track 01.bin", "Game Track 02.bin").
    // This avoids over-granting when multiple games share the same directory.
    private fun grantSiblingTrackPermissions(context: Context, packageName: String, masterUri: Uri) {
        val trackExts = setOf("bin", "iso", "img", "sub", "wav", "flac", "dat")
        try {
            val treeDocId = android.provider.DocumentsContract.getTreeDocumentId(masterUri)
            val docId = android.provider.DocumentsContract.getDocumentId(masterUri)
            val parentDocId = if (docId.contains('/')) docId.substringBeforeLast('/') else treeDocId
            val treeUri = android.provider.DocumentsContract.buildTreeDocumentUri(masterUri.authority, treeDocId)
            val childrenUri = android.provider.DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentDocId)

            val masterFileName = getFileNameFromUri(context, masterUri) ?: ""
            val masterBase = masterFileName.substringBeforeLast('.').lowercase()

            context.contentResolver.query(
                childrenUri,
                arrayOf(
                    android.provider.DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME
                ),
                null, null, null
            )?.use { cursor ->
                while (cursor.moveToNext()) {
                    val childDocId = cursor.getString(0) ?: continue
                    val childName = cursor.getString(1) ?: continue
                    val childNameLower = childName.lowercase()
                    val childExt = childName.substringAfterLast('.', "").lowercase()
                    val childBase = childName.substringBeforeLast('.').lowercase()

                    val sameBaseName = childBase == masterBase
                    val isTrackSibling = childExt in trackExts && childNameLower.startsWith(masterBase)

                    if (sameBaseName || isTrackSibling) {
                        val childUri = android.provider.DocumentsContract.buildDocumentUriUsingTree(treeUri, childDocId)
                        try {
                            context.grantUriPermission(packageName, childUri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        } catch (_: Exception) {}
                    }
                }
            }
        } catch (_: Exception) {}
    }
}
