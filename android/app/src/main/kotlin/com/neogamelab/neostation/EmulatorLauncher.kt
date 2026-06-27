package com.neogamelab.neostation

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
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
        keepSafUri: Boolean,
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
            // injected by the Dart launcher when the JSON config uses {file.path}
            // or {file.localuri} placeholders. All other values pass
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

            // Convert SAF content:// URIs to our own FileProvider URI.
            // FileProvider URIs cannot be easily resolved to real filesystem paths by
            // receiving apps, so emulators (e.g. .emu series) fall back to saving in
            // their private data directory instead of trying (and failing) to write
            // save states (.frz) next to the ROM. This matches Pegasus behaviour.
            //
            // EXCEPTION: Multi-file formats (.cue, .gdi, .m3u) are NOT converted.
            // These files contain relative paths to sibling track files (.bin, .iso).
            // Emulators like DuckStation read the cue, extract the relative filename,
            // and then try to open it as a local file. If we pass a FileProvider URI
            // for the cue, the emulator cannot determine the base directory to resolve
            // the relative path, so it fails to find the .bin. Keeping the original SAF
            // URI allows the emulator to resolve the real directory and find siblings.
            var masterRealPath: String? = null
            var isMultiFile = false
            // Emulators that need real filesystem paths for multi-file ROMs
            // because they resolve sibling track files via relative paths.
            val needsRealPathForMultiFile = packageName in setOf(
                "com.github.stenzek.duckstation"
            )
            if (uriData?.scheme == "content") {
                masterRealPath = resolveSafUriToPath(context, uriData)
                val masterFileName = getFileNameFromUri(context, uriData) ?: ""
                val masterExt = masterFileName.substringAfterLast('.', "").lowercase()
                isMultiFile = masterExt in setOf("cue", "gdi", "m3u")

                // Whether this emulator must receive the original SAF content:// URI
                // instead of our FileProvider rewrap. Driven by the per-emulator
                // `keep_saf_uri` flag in the system JSON (Flycast needs it so .zip
                // loading works; DraStic rejects our FileProvider URI). Config-driven
                // so no emulator package names are hardcoded here.
                val keepsSafUri = keepSafUri
                if (masterRealPath != null && !isMultiFile && !keepsSafUri) {
                    // Single-file ROMs (.sfc, .gba, etc.): convert to FileProvider URI
                    // so .emu emulators save states in their private data dir.
                    val providerUri = resolveToFileProviderUri(context, uriData)
                    if (providerUri != null) {
                        uriData = providerUri
                    }
                } else if (masterRealPath != null && isMultiFile && needsRealPathForMultiFile) {
                    // Only convert to file:// for emulators that need real paths
                    // to resolve sibling track files. Others keep SAF URI with grants.
                    uriData = Uri.parse("file://$masterRealPath")
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
                        val libretroDir = getDefaultLibretroDirectory(context, packageName)
                        val base = finalValue
                            .removeSuffix("_libretro_android.so")
                            .removeSuffix("_libretro.so")
                        intent.putExtra(key, "$libretroDir${base}_libretro_android.so")
                        continue
                    }

                    val resolvedFinalValue = if (finalValue.startsWith("content://") && needsRealPathForMultiFile) {
                        resolveMultiFileExtraToFileUri(context, finalValue)
                    } else {
                        finalValue
                    }

                    when (valueType) {
                        "string" -> intent.putExtra(key, resolvedFinalValue)
                        "bool" -> intent.putExtra(key, resolvedFinalValue.toBoolean())
                        "int" -> intent.putExtra(key, resolvedFinalValue.toIntOrNull() ?: 0)
                        "long" -> intent.putExtra(key, resolvedFinalValue.toLongOrNull() ?: 0L)
                        "float" -> intent.putExtra(key, resolvedFinalValue.toFloatOrNull() ?: 0.0f)
                        "uri" -> intent.putExtra(key, Uri.parse(resolvedFinalValue))
                        "string_array" -> intent.putExtra(
                            key, resolvedFinalValue.split(",").map { it.trim() }.toTypedArray()
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
                // WRITE permission is also granted so emulators (e.g. .emu series) can
                // create save states (.frz) and SRAM files in the ROM directory.
                try {
                    context.grantUriPermission(
                        packageName,
                        primaryContentUri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    )
                } catch (_: Exception) { }

                intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                intent.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                if (intent.clipData == null) {
                    intent.clipData = ClipData.newRawUri("ROM", primaryContentUri)
                }

                // Grant permission to the parent directory tree so the emulator can read
                // sibling files, subfolders, or write saves next to the ROM (e.g. Flycast
                // reading .chd inside a subfolder, or .emu creating .frz states).
                // This is safe and cheap — emulators that don't need it simply ignore the URI.
                grantParentTreePermission(context, packageName, intent, primaryContentUri)

                // For .zip ROMs that ship with a side-car folder (same name as the zip,
                // without extension), grant explicit read permission to every file inside
                // that subfolder so the emulator can open them directly (e.g. Flycast
                // opening .chd files inside a NAOMI GD / NAOMI2 game folder).
                grantSubfolderContentsIfZip(context, packageName, intent, primaryContentUri)

                // Multi-file formats (.cue, .gdi, .m3u) reference sibling track files
                // (.bin, .iso, .img, .wav, etc.) that also need explicit URI permissions.
                // Without this, the emulator can open the cue/gdi but gets permission
                // denied when it tries to read the actual track data.
                val masterFileName = getFileNameFromUri(context, primaryContentUri) ?: ""
                val masterExt = masterFileName.substringAfterLast('.', "").lowercase()
                if (masterExt in setOf("cue", "gdi", "m3u")) {
                    if (isMultiFile && android.provider.DocumentsContract.isDocumentUri(context, primaryContentUri) &&
                        !needsRealPathForMultiFile) {
                        // For emulators that handle SAF natively (Flycast, etc.):
                        // Keep SAF URI and grant permissions to sibling track files.
                        // Document URIs work here — getTreeDocumentId extracts the tree
                        // portion from the document ID automatically.
                        grantSiblingTrackPermissions(context, packageName, intent, primaryContentUri)
                    } else if (masterRealPath != null) {
                        // For emulators needing real paths (DuckStation) or as fallback:
                        // Use FileProvider URIs for siblings.
                        grantSiblingFileProviderPermissions(context, packageName, intent, masterRealPath)
                    }
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
    //  neostation-realpath:<uri>  → best-effort real filesystem path: resolves SAF
    //                               content:// directly; falls back to a local cache
    //                               copy for network/NAS providers (Round Sync, CIFS…)
    //                               that have no filesystem mapping.
    //  neostation-localuri:<uri> → passes content:// URIs through as-is so that
    //                                 launchGenericIntent can grant read permissions.
    //                                 Bare local paths become file:// URI.
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
            value.startsWith("neostation-localuri:") -> {
                val raw = value.removePrefix("neostation-localuri:")
                // Keep content:// URIs as-is so launchGenericIntent can grant
                // FLAG_GRANT_READ_URI_PERMISSION. Converting to file:// breaks on
                // Android 10+ scoped storage where the target emulator lacks read
                // access to the resolved external-storage path.
                if (raw.startsWith("content://")) {
                    raw
                } else if (raw.startsWith("file://")) {
                    raw
                } else {
                    "file://$raw"
                }
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
            // Use public external storage so other apps (e.g. RetroArch) can read the cached ROM.
            // Android 10+ blocks cross-app access to Android/data/<pkg>/cache/, but public
            // directories under the root of external storage are accessible to any app with
            // READ_EXTERNAL_STORAGE / MANAGE_EXTERNAL_STORAGE.
            val publicDir = File(Environment.getExternalStorageDirectory(), "NeoStation/rom_import")
            val importDir = if (publicDir.mkdirs() || publicDir.exists()) publicDir
                            else File(context.externalCacheDir ?: context.cacheDir, ROM_IMPORT_DIR).also { it.mkdirs() }
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

    private fun getDefaultLibretroDirectory(context: Context, retroArchPackage: String): String {
        return try {
            val appInfo = context.packageManager.getApplicationInfo(retroArchPackage, 0)
            "${appInfo.dataDir}/cores/"
        } catch (_: Exception) {
            "/data/user/0/$retroArchPackage/cores/"
        }
    }

    private fun isExternalStorageDocument(uri: Uri): Boolean {
        return "com.android.externalstorage.documents" == uri.authority
    }

    // Grants URI permission to the SAF tree root that contains the file so the emulator
    // can read sibling files and navigate subfolders (e.g. Flycast reading .chd files
    // inside a NAOMI GD / NAOMI2 game subfolder).  We grant permission to the actual
    // tree root (obtained via getTreeDocumentId) and add FLAG_GRANT_PREFIX_URI_PERMISSION
    // so the permission propagates to every descendant document in the tree.
    private fun grantParentTreePermission(context: Context, packageName: String, intent: Intent, fileUri: Uri) {
        try {
            if (!android.provider.DocumentsContract.isDocumentUri(context, fileUri)) return
            val treeDocId = android.provider.DocumentsContract.getTreeDocumentId(fileUri)
            val treeUri = android.provider.DocumentsContract.buildTreeDocumentUri(fileUri.authority, treeDocId)

            context.grantUriPermission(
                packageName,
                treeUri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )

            // FLAG_GRANT_PREFIX_URI_PERMISSION is required for tree URIs so that the
            // receiving app can access every descendant document in the tree, not just
            // the tree root itself.
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            intent.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                intent.addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
            }

            if (intent.clipData == null) {
                intent.clipData = ClipData.newRawUri("ROM_DIR", treeUri)
            } else {
                intent.clipData?.addItem(ClipData.Item(treeUri))
            }
        } catch (_: Exception) { }
    }

    // When a ROM is a .zip that ships with a side-car folder (same name without .zip),
    // some emulators (e.g. Flycast for NAOMI GD / NAOMI2) need to read files inside that
    // folder.  We find the sibling folder in the same directory, list every file inside
    // it, and grant explicit read permission to each individual file so the emulator
    // can open them directly via ContentResolver.
    private fun grantSubfolderContentsIfZip(context: Context, packageName: String, intent: Intent, fileUri: Uri) {
        try {
            if (!android.provider.DocumentsContract.isDocumentUri(context, fileUri)) return
            val fileName = getFileNameFromUri(context, fileUri) ?: return
            if (!fileName.endsWith(".zip", ignoreCase = true)) return

            val docId = android.provider.DocumentsContract.getDocumentId(fileUri)
            if (!docId.contains('/')) return
            val authority = fileUri.authority ?: return

            // Name of the expected sibling folder (same as zip without extension)
            val folderName = fileName.substringBeforeLast('.', "")
            if (folderName.isEmpty()) return

            // Parent directory of the zip file
            val parentDocId = docId.substringBeforeLast('/')
            val parentTreeUri = android.provider.DocumentsContract.buildTreeDocumentUri(authority, parentDocId)
            val parentChildrenUri = android.provider.DocumentsContract.buildChildDocumentsUriUsingTree(parentTreeUri, parentDocId)

            // Look for the sibling folder in the parent directory
            var subfolderDocId: String? = null
            context.contentResolver.query(
                parentChildrenUri,
                arrayOf(
                    android.provider.DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    android.provider.DocumentsContract.Document.COLUMN_MIME_TYPE
                ),
                null, null, null
            )?.use { cursor ->
                while (cursor.moveToNext()) {
                    val childDocId = cursor.getString(0) ?: continue
                    val childName = cursor.getString(1) ?: continue
                    val mimeType = cursor.getString(2) ?: continue
                    if (childName == folderName && mimeType == android.provider.DocumentsContract.Document.MIME_TYPE_DIR) {
                        subfolderDocId = childDocId
                        break
                    }
                }
            }
            if (subfolderDocId == null) return

            // Build tree URI for the subfolder and grant read permission
            val subfolderTreeUri = android.provider.DocumentsContract.buildTreeDocumentUri(authority, subfolderDocId)
            try {
                context.grantUriPermission(
                    packageName,
                    subfolderTreeUri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
                intent.clipData?.addItem(ClipData.Item(subfolderTreeUri))
            } catch (_: Exception) {}

            // List every file inside the subfolder and grant explicit read permission
            val subfolderChildrenUri = android.provider.DocumentsContract.buildChildDocumentsUriUsingTree(subfolderTreeUri, subfolderDocId)
            context.contentResolver.query(
                subfolderChildrenUri,
                arrayOf(
                    android.provider.DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME
                ),
                null, null, null
            )?.use { cursor ->
                while (cursor.moveToNext()) {
                    val childDocId = cursor.getString(0) ?: continue
                    val childName = cursor.getString(1) ?: continue
                    val childUri = android.provider.DocumentsContract.buildDocumentUriUsingTree(subfolderTreeUri, childDocId)
                    try {
                        context.grantUriPermission(
                            packageName,
                            childUri,
                            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                        )
                        intent.clipData?.addItem(ClipData.Item(childUri))
                    } catch (_: Exception) {}
                }
            }
        } catch (_: Exception) { }
    }

    // Grants read permission for sibling track files belonging to the same disc image.
    // Matches: (1) any extension with the exact same base name, or (2) track files whose
    // name starts with the master base name (e.g. "Game Track 01.bin", "Game Track 02.bin").
    // This avoids over-granting when multiple games share the same directory.
    private fun grantSiblingTrackPermissions(context: Context, packageName: String, intent: Intent, masterUri: Uri) {
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
                            // Add sibling URIs to ClipData so the emulator can access them
                            // via ContentResolver. Without this, grantUriPermission alone may
                            // not be sufficient for some emulators (e.g. DuckStation).
                            intent.clipData?.addItem(ClipData.Item(childUri))
                        } catch (_: Exception) {}
                    }
                }
            }
        } catch (_: Exception) {}
    }

    // Converts a SAF content:// URI (e.g. com.android.externalstorage.documents)
    // to a FileProvider URI owned by NeoStation. Receiving apps can read the file
    // via ContentResolver, but cannot easily resolve it back to a real filesystem
    // path. This prevents emulators like the .emu series from attempting to write
    // save states next to the ROM (which fails on Android 10+ scoped storage).
    private fun resolveToFileProviderUri(context: Context, contentUri: Uri): Uri? {
        val realPath = resolveSafUriToPath(context, contentUri)
        if (realPath != null) {
            val file = File(realPath)
            if (file.exists()) {
                return try {
                    FileProvider.getUriForFile(
                        context,
                        "${context.packageName}.fileprovider",
                        file
                    )
                } catch (e: Exception) {
                    null
                }
            }
        }
        return null
    }

    // If the extra value is a content:// URI pointing to a multi-file format (.cue, .gdi, .m3u),
    // resolves it to a file:// URI so the emulator can read sibling track files via the
    // real filesystem. For all other URIs returns the original value unchanged.
    private fun resolveMultiFileExtraToFileUri(context: Context, value: String): String {
        if (!value.startsWith("content://")) return value
        val uri = Uri.parse(value)
        val fileName = getFileNameFromUri(context, uri) ?: return value
        val ext = fileName.substringAfterLast('.', "").lowercase()
        if (ext !in setOf("cue", "gdi", "m3u")) return value
        val realPath = resolveSafUriToPath(context, uri) ?: return value
        return "file://$realPath"
    }

    // Grants read+write permission for sibling track files when using FileProvider URIs.
    // Used for multi-file formats (.cue, .gdi, .m3u) that reference sibling files.
    private fun grantSiblingFileProviderPermissions(
        context: Context,
        packageName: String,
        intent: Intent,
        masterRealPath: String
    ) {
        val trackExts = setOf("bin", "iso", "img", "sub", "wav", "flac", "dat", "raw", "ogg", "mp3")
        try {
            val masterFile = File(masterRealPath)
            val parentDir = masterFile.parentFile ?: return
            val masterBase = masterFile.nameWithoutExtension.lowercase()

            parentDir.listFiles()?.forEach { file ->
                if (file == masterFile) return@forEach
                val childNameLower = file.name.lowercase()
                val childExt = file.extension.lowercase()
                val childBase = file.nameWithoutExtension.lowercase()

                val sameBaseName = childBase == masterBase
                val isTrackSibling = childExt in trackExts && childNameLower.startsWith(masterBase)

                if (sameBaseName || isTrackSibling) {
                    try {
                        val siblingUri = FileProvider.getUriForFile(
                            context,
                            "${context.packageName}.fileprovider",
                            file
                        )
                        context.grantUriPermission(
                            packageName,
                            siblingUri,
                            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                        )
                        intent.clipData?.addItem(ClipData.Item(siblingUri))
                    } catch (_: Exception) {}
                }
            }
        } catch (_: Exception) {}
    }
}
