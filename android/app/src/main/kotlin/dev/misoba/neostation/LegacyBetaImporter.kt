package dev.misoba.neostation

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors

/**
 * Copies the user data of a NeoStation beta into this install.
 *
 * The betas were published as `com.neogamelab.neostation`, a different app as
 * far as Android is concerned, so their `Android/data` folder can't be read
 * from here. Every beta does publish that folder (or the one chosen in its
 * Settings) as a root in the Files app, through its NeoDocumentsProvider, so
 * the user picks that root once and the whole tree is copied from it: the
 * database with its -wal and -shm files, media, themes and the rest.
 *
 * The beta's sign-ins live in its Android Keystore and its preferences in its
 * private storage; neither can leave it, so those are not imported.
 */
class LegacyBetaImporter(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    companion object {
        const val CHANNEL = "dev.misoba.neostation/legacy_import"
        const val LEGACY_PACKAGE = "com.neogamelab.neostation"
        const val LEGACY_AUTHORITY = "$LEGACY_PACKAGE.documents"
        const val PICK_REQUEST_CODE = 9311
        const val GRANT_REQUEST_CODE = 9312

        // NeoDocumentsProvider's one root, in every beta.
        private const val LEGACY_ROOT_ID = "root"
        private const val BUFFER_SIZE = 1 shl 20
        private const val PROGRESS_INTERVAL_MS = 250L
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var pickResult: MethodChannel.Result? = null
    private var grantResult: MethodChannel.Result? = null
    private var grantRequested: Uri? = null

    @Volatile
    private var cancelled = false

    init {
        channel.setMethodCallHandler(::onMethodCall)
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "legacyInstall" -> result.success(legacyInstall())
            "pickLegacyFolder" -> pickLegacyFolder(result)
            "grantFolder" -> {
                val tree = call.argument<String>("treeUri")
                if (tree == null) {
                    result.error("INVALID_ARGUMENTS", "treeUri is required", null)
                    return
                }
                grantFolder(Uri.parse(tree), result)
            }
            "measure" -> {
                val tree = call.argument<String>("treeUri")
                if (tree == null) {
                    result.error("INVALID_ARGUMENTS", "treeUri is required", null)
                    return
                }
                runInBackground(result) { measure(Uri.parse(tree)).toMap() }
            }
            "copy" -> {
                val tree = call.argument<String>("treeUri")
                val destination = call.argument<String>("destination")
                if (tree == null || destination == null) {
                    result.error("INVALID_ARGUMENTS", "treeUri and destination are required", null)
                    return
                }
                cancelled = false
                runInBackground(result) {
                    copyTree(Uri.parse(tree), File(destination)).toMap()
                }
            }
            "cancel" -> {
                cancelled = true
                result.success(null)
            }
            "freeBytes" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("INVALID_ARGUMENTS", "path is required", null)
                    return
                }
                result.success(freeBytes(File(path)))
            }
            "uninstallLegacy" -> {
                try {
                    activity.startActivity(
                        Intent(Intent.ACTION_DELETE, Uri.parse("package:$LEGACY_PACKAGE"))
                    )
                    result.success(true)
                } catch (e: Exception) {
                    result.success(false)
                }
            }
            else -> result.notImplemented()
        }
    }

    /** The installed beta's version, or null when no beta is installed. */
    private fun legacyInstall(): Map<String, Any?>? {
        return try {
            val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                activity.packageManager.getPackageInfo(
                    LEGACY_PACKAGE,
                    PackageManager.PackageInfoFlags.of(0),
                )
            } else {
                @Suppress("DEPRECATION")
                activity.packageManager.getPackageInfo(LEGACY_PACKAGE, 0)
            }
            val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                info.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                info.versionCode.toLong()
            }
            mapOf("versionName" to info.versionName, "versionCode" to code)
        } catch (e: PackageManager.NameNotFoundException) {
            null
        }
    }

    /**
     * Opens the system folder picker on the beta's root. Answers with the
     * picked tree and whether it is the beta's (a folder from anywhere else
     * can be picked too, and is refused by the caller).
     */
    private fun pickLegacyFolder(result: MethodChannel.Result) {
        if (pickResult != null) {
            result.error("PICK_IN_PROGRESS", "A folder picker is already open", null)
            return
        }
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    // The root's URI, not its document's: the system picker
                    // ignores a document URI from another app's provider and
                    // opens on internal storage, while a root URI opens it on
                    // the beta's folder, ready for "Use this folder" (seen on
                    // Android 13's DocumentsUI).
                    putExtra(
                        DocumentsContract.EXTRA_INITIAL_URI,
                        DocumentsContract.buildRootUri(LEGACY_AUTHORITY, LEGACY_ROOT_ID),
                    )
                }
            }
            pickResult = result
            activity.startActivityForResult(intent, PICK_REQUEST_CODE)
        } catch (e: Exception) {
            pickResult = null
            result.error("PICKER_FAILED", e.message, null)
        }
    }

    /**
     * Opens the folder picker on [tree], a ROM folder the beta had access to,
     * so the user can give this app the same access. The grant is per app, so
     * the imported library lists the folder but can't read it until then.
     * Answers with whether the folder picked was that one; a different folder
     * is let go again, since the library doesn't point at it.
     */
    private fun grantFolder(tree: Uri, result: MethodChannel.Result) {
        if (grantResult != null || pickResult != null) {
            result.error("PICK_IN_PROGRESS", "A folder picker is already open", null)
            return
        }
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                )
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    putExtra(
                        DocumentsContract.EXTRA_INITIAL_URI,
                        DocumentsContract.buildDocumentUriUsingTree(
                            tree,
                            DocumentsContract.getTreeDocumentId(tree),
                        ),
                    )
                }
            }
            grantResult = result
            grantRequested = tree
            activity.startActivityForResult(intent, GRANT_REQUEST_CODE)
        } catch (e: Exception) {
            grantResult = null
            grantRequested = null
            result.error("PICKER_FAILED", e.message, null)
        }
    }

    private fun sameTree(a: Uri, b: Uri): Boolean = try {
        a.authority == b.authority &&
            DocumentsContract.getTreeDocumentId(a) == DocumentsContract.getTreeDocumentId(b)
    } catch (e: IllegalArgumentException) {
        false
    }

    private fun onGrantResult(resultCode: Int, data: Intent?) {
        val result = grantResult ?: return
        val requested = grantRequested
        grantResult = null
        grantRequested = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || requested == null) {
            result.success(null)
            return
        }
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or
            Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        if (!sameTree(uri, requested)) {
            result.success(mapOf("granted" to false, "treeUri" to uri.toString()))
            return
        }
        try {
            activity.contentResolver.takePersistableUriPermission(uri, flags)
            result.success(mapOf("granted" to true, "treeUri" to uri.toString()))
        } catch (e: SecurityException) {
            result.error("NO_ACCESS", e.message, null)
        }
    }

    /** Hands the picker's answer back. True when [requestCode] was ours. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == GRANT_REQUEST_CODE) {
            onGrantResult(resultCode, data)
            return true
        }
        if (requestCode != PICK_REQUEST_CODE) return false
        val result = pickResult ?: return true
        pickResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return true
        }
        val isLegacy = uri.authority == LEGACY_AUTHORITY
        val isRoot = isLegacy && try {
            DocumentsContract.getTreeDocumentId(uri) == LEGACY_ROOT_ID
        } catch (e: IllegalArgumentException) {
            false
        }
        result.success(
            mapOf(
                "treeUri" to uri.toString(),
                "isLegacy" to isLegacy,
                // The beta's user-data folder itself, not a folder inside it:
                // a subfolder would import only part of the library.
                "isRoot" to isRoot,
                // It holds a library: a beta that was never set up has nothing
                // to bring over.
                "hasLibrary" to (isRoot && hasLibrary(uri)),
            )
        )
        return true
    }

    /** Whether the picked tree holds the beta's database. */
    private fun hasLibrary(tree: Uri): Boolean = try {
        children(tree, DocumentsContract.getTreeDocumentId(tree)).any {
            !it.isDirectory && it.name == "data.sqlite"
        }
    } catch (e: Exception) {
        false
    }

    private data class Totals(var files: Long = 0, var bytes: Long = 0) {
        fun toMap(): Map<String, Any> = mapOf("files" to files, "bytes" to bytes)
    }

    private data class Child(
        val documentId: String,
        val name: String,
        val isDirectory: Boolean,
        val size: Long,
    )

    private fun children(tree: Uri, parentId: String): List<Child> {
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
        val projection = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_SIZE,
        )
        val list = mutableListOf<Child>()
        activity.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getString(0) ?: continue
                val name = cursor.getString(1) ?: continue
                val mime = cursor.getString(2)
                val size = if (cursor.isNull(3)) 0L else cursor.getLong(3)
                list.add(Child(id, name, mime == Document.MIME_TYPE_DIR, size))
            }
        } ?: throw IOException("Cannot list $parentId")
        return list
    }

    // A name from the provider used as one path component here: anything that
    // could climb out of the destination is refused.
    private fun safeName(name: String): String {
        if (name.isEmpty() || name == "." || name == ".." || name.contains('/') ||
            name.contains('\u0000')
        ) {
            throw IOException("Unsafe file name: $name")
        }
        return name
    }

    private fun walk(tree: Uri, visit: (Child, List<String>) -> Unit) {
        val rootId = DocumentsContract.getTreeDocumentId(tree)
        val pending = ArrayDeque<Pair<String, List<String>>>()
        pending.add(rootId to emptyList())
        while (pending.isNotEmpty()) {
            if (cancelled) throw InterruptedException("Cancelled")
            val (id, path) = pending.removeFirst()
            for (child in children(tree, id)) {
                val childPath = path + safeName(child.name)
                visit(child, childPath)
                if (child.isDirectory) pending.add(child.documentId to childPath)
            }
        }
    }

    private fun measure(tree: Uri): Totals {
        val totals = Totals()
        walk(tree) { child, _ ->
            if (!child.isDirectory) {
                totals.files++
                totals.bytes += child.size
            }
        }
        return totals
    }

    private fun copyTree(tree: Uri, destination: File): Totals {
        val totals = Totals()
        var lastReport = 0L
        if (!destination.isDirectory && !destination.mkdirs()) {
            throw IOException("Cannot create ${destination.path}")
        }
        val buffer = ByteArray(BUFFER_SIZE)
        walk(tree) { child, path ->
            val target = File(destination, path.joinToString(File.separator))
            if (child.isDirectory) {
                if (!target.isDirectory && !target.mkdirs()) {
                    throw IOException("Cannot create ${target.path}")
                }
                return@walk
            }
            target.parentFile?.let { if (!it.isDirectory) it.mkdirs() }
            val source = DocumentsContract.buildDocumentUriUsingTree(tree, child.documentId)
            val input = activity.contentResolver.openInputStream(source)
                ?: throw IOException("Cannot open ${path.joinToString("/")}")
            input.use { stream ->
                target.outputStream().use { out ->
                    while (true) {
                        if (cancelled) throw InterruptedException("Cancelled")
                        val read = stream.read(buffer)
                        if (read < 0) break
                        out.write(buffer, 0, read)
                        totals.bytes += read
                        val now = System.currentTimeMillis()
                        if (now - lastReport >= PROGRESS_INTERVAL_MS) {
                            lastReport = now
                            reportProgress(totals.files, totals.bytes)
                        }
                    }
                    out.fd.sync()
                }
            }
            totals.files++
        }
        reportProgress(totals.files, totals.bytes)
        return totals
    }

    private fun reportProgress(files: Long, bytes: Long) {
        main.post {
            channel.invokeMethod("progress", mapOf("files" to files, "bytes" to bytes))
        }
    }

    private fun freeBytes(path: File): Long? {
        var dir: File? = path
        while (dir != null && !dir.exists()) dir = dir.parentFile
        return try {
            dir?.let { StatFs(it.path).availableBytes }
        } catch (e: IllegalArgumentException) {
            null
        }
    }

    private fun runInBackground(result: MethodChannel.Result, work: () -> Any?) {
        executor.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: InterruptedException) {
                main.post { result.error("CANCELLED", "Import cancelled", null) }
            } catch (e: SecurityException) {
                main.post { result.error("NO_ACCESS", e.message, null) }
            } catch (e: Exception) {
                main.post { result.error("COPY_FAILED", e.message, null) }
            }
        }
    }
}
