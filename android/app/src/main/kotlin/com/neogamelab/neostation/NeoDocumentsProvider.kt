package com.neogamelab.neostation

import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import android.webkit.MimeTypeMap

import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.text.Normalizer
import java.util.Locale

/**
 * NeoStation's user-data folder as a root in Android's Files app.
 *
 * On recent Android the default user-data folder (under `Android/data`) is
 * hard to reach on the device any other way: this is where users drop their
 * own art into `media/`, add themes or fetch `app.log`. Files can be copied
 * and moved in and out, folders created, and entries renamed and deleted;
 * copying and moving go through the Files app's own create-then-write. The
 * database stays listed so it can be copied for a bug report, but can't be
 * changed here.
 */
class NeoDocumentsProvider : DocumentsProvider() {

    companion object {
        // Constants
        private const val DEFAULT_ROOT_ID = "root"
        private const val ROOT_NAME = "NeoStation"

        // The open database: changing or deleting it from outside the app
        // would lose or corrupt the library. Compared after folding a name
        // the way shared storage and SD cards match names (see [fold]).
        private val PROTECTED_NAMES = setOf(
            "data.sqlite",
            "data.sqlite-wal",
            "data.sqlite-shm",
            "data.sqlite-journal",
        )

        // Columns
        private val DEFAULT_ROOT_PROJECTION: Array<String> = arrayOf(
            Root.COLUMN_ROOT_ID,
            Root.COLUMN_MIME_TYPES,
            Root.COLUMN_FLAGS,
            Root.COLUMN_ICON,
            Root.COLUMN_TITLE,
            Root.COLUMN_SUMMARY,
            Root.COLUMN_DOCUMENT_ID,
            Root.COLUMN_AVAILABLE_BYTES
        )

        private val DEFAULT_DOCUMENT_PROJECTION: Array<String> = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_LAST_MODIFIED,
            Document.COLUMN_FLAGS,
            Document.COLUMN_SIZE
        )
    }

    override fun onCreate(): Boolean = true

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val result = MatrixCursor(projection ?: DEFAULT_ROOT_PROJECTION)
        val base = baseDir() ?: return result
        val row = result.newRow()

        row.add(Root.COLUMN_ROOT_ID, DEFAULT_ROOT_ID)
        row.add(Root.COLUMN_ICON, R.mipmap.launcher_icon)
        row.add(Root.COLUMN_TITLE, ROOT_NAME)
        row.add(Root.COLUMN_DOCUMENT_ID, DEFAULT_ROOT_ID)
        row.add(Root.COLUMN_MIME_TYPES, "*/*")
        row.add(Root.COLUMN_FLAGS, Root.FLAG_SUPPORTS_CREATE or Root.FLAG_SUPPORTS_IS_CHILD)
        row.add(Root.COLUMN_AVAILABLE_BYTES, base.freeSpace)

        return result
    }

    override fun queryChildDocuments(
        parentDocumentId: String?,
        projection: Array<out String>?,
        sortOrder: String?
    ): Cursor {
        val result = MatrixCursor(projection ?: DEFAULT_DOCUMENT_PROJECTION)
        val base = requireBase()
        val parent = resolve(base, parentDocumentId)

        parent.listFiles()?.forEach { file ->
            includeFile(result, base, file)
        }
        // So the Files app refreshes the listing after a change.
        childrenUri(base, parent)?.let { uri ->
            context?.let { result.setNotificationUri(it.contentResolver, uri) }
        }
        return result
    }

    override fun queryDocument(documentId: String?, projection: Array<out String>?): Cursor {
        val result = MatrixCursor(projection ?: DEFAULT_DOCUMENT_PROJECTION)
        val base = requireBase()
        val file = resolve(base, documentId)

        if (!file.exists()) {
            throw FileNotFoundException("Missing document: $documentId")
        }

        includeFile(result, base, file)
        return result
    }

    override fun openDocument(
        documentId: String?,
        mode: String?,
        signal: CancellationSignal?
    ): ParcelFileDescriptor {
        val base = requireBase()
        val file = resolve(base, documentId)
        val accessMode = ParcelFileDescriptor.parseMode(mode)
        if (accessMode == ParcelFileDescriptor.MODE_READ_ONLY) {
            return ParcelFileDescriptor.open(file, accessMode)
        }
        if (isProtected(base, file)) {
            throw FileNotFoundException("Read-only: $documentId")
        }
        // A written file changes the listing once it's closed. The folder is
        // worked out now: the user data may have moved by then.
        val changed = childrenUri(base, file.parentFile)
        return ParcelFileDescriptor.open(file, accessMode, Handler(Looper.getMainLooper())) {
            notifyChange(changed)
        }
    }

    override fun getDocumentType(documentId: String?): String {
        return getMimeType(resolve(requireBase(), documentId))
    }

    override fun createDocument(
        parentDocumentId: String?,
        mimeType: String?,
        displayName: String?
    ): String {
        val base = requireBase()
        val parent = resolve(base, parentDocumentId)
        if (!parent.isDirectory) {
            throw FileNotFoundException("Not a folder: $parentDocumentId")
        }
        val isDirectory = mimeType == Document.MIME_TYPE_DIR
        var name = validName(displayName)
        // Only a known type gets an extension: "LICENSE" stays "LICENSE".
        if (!isDirectory && !name.contains('.') &&
            mimeType != null && mimeType != "application/octet-stream"
        ) {
            MimeTypeMap.getSingleton().getExtensionFromMimeType(mimeType)?.let {
                name = "$name.$it"
            }
        }
        val target = uniqueChild(base, parent, name)
        val created = try {
            if (isDirectory) target.mkdir() else target.createNewFile()
        } catch (e: IOException) {
            throw FileNotFoundException("Couldn't create ${target.name}: ${e.message}")
        }
        if (!created) {
            throw FileNotFoundException("Couldn't create ${target.name}")
        }
        notifyChange(childrenUri(base, parent))
        return docIdOf(base, target)
            ?: throw FileNotFoundException("Outside the user-data folder: ${target.name}")
    }

    override fun deleteDocument(documentId: String?) {
        val base = requireBase()
        val file = resolve(base, documentId)
        if (file == base || isProtected(base, file)) {
            throw SecurityException("Can't delete: $documentId")
        }
        if (!file.deleteRecursively()) {
            throw IllegalStateException("Couldn't delete: $documentId")
        }
        notifyChange(childrenUri(base, file.parentFile))
    }

    override fun renameDocument(documentId: String?, displayName: String?): String {
        val base = requireBase()
        val file = resolve(base, documentId)
        if (file == base || isProtected(base, file)) {
            throw SecurityException("Can't rename: $documentId")
        }
        val parent = file.parentFile ?: throw FileNotFoundException("No parent: $documentId")
        val name = validName(displayName)
        val target = parent.resolve(name)
        if (parent == base && (name == DEFAULT_ROOT_ID || isProtected(base, target))) {
            throw IllegalArgumentException("Reserved name: $name")
        }
        if (target.exists()) {
            throw IllegalStateException("Already exists: $name")
        }
        if (!file.renameTo(target)) {
            throw IllegalStateException("Couldn't rename: $documentId")
        }
        notifyChange(childrenUri(base, parent))
        return docIdOf(base, target)
            ?: throw FileNotFoundException("Outside the user-data folder: $name")
    }

    override fun isChildDocument(parentDocumentId: String?, documentId: String?): Boolean {
        return try {
            val base = requireBase()
            val parent = resolve(base, parentDocumentId)
            val child = resolve(base, documentId)
            child != parent && child.path.startsWith(parent.path + File.separator)
        } catch (e: FileNotFoundException) {
            false
        }
    }

    // --- Helpers ---

    // The user-data folder, looked up once per call: it can move while the app
    // keeps running (the setup wizard, or Settings' restart, which doesn't end
    // the process), and the Files app must follow it.
    private fun baseDir(): File? {
        val context = context ?: return null
        val prefs = context.getSharedPreferences(
            "FlutterSharedPreferences",
            android.content.Context.MODE_PRIVATE,
        )
        val customPath = prefs.getString("flutter.custom_user_data_path", null)
        val dir = if (!customPath.isNullOrEmpty()) {
            File(customPath)
        } else {
            val root = context.getExternalFilesDir(null) ?: return null
            File(root, "user-data")
        }
        if (!dir.exists()) {
            dir.mkdirs()
        }
        return try {
            dir.canonicalFile
        } catch (e: IOException) {
            null
        }
    }

    private fun requireBase(): File =
        baseDir() ?: throw FileNotFoundException("No user-data folder")

    // The file for [docId]: every id resolves inside [base], or isn't found.
    private fun resolve(base: File, docId: String?): File {
        if (docId.isNullOrEmpty() || docId == DEFAULT_ROOT_ID) {
            return base
        }
        val file = try {
            File(base, docId).canonicalFile
        } catch (e: IOException) {
            throw FileNotFoundException("Unreadable id: $docId")
        }
        if (file != base && !file.path.startsWith(base.path + File.separator)) {
            throw FileNotFoundException("Outside the user-data folder: $docId")
        }
        return file
    }

    // A new or renamed entry's name: one plain name, never a path.
    private fun validName(name: String?): String {
        val trimmed = name?.trim() ?: ""
        if (trimmed.isEmpty() || trimmed == "." || trimmed == ".." ||
            trimmed.contains('/') || trimmed.contains('\u0000')
        ) {
            throw IllegalArgumentException("Not a valid name: $name")
        }
        return trimmed
    }

    // [name] in [parent], or "name (1).ext", "name (2).ext"… if it's taken.
    // A top-level entry can't take the root's own id or a database name.
    private fun uniqueChild(base: File, parent: File, name: String): File {
        val atTop = parent == base
        val dot = name.lastIndexOf('.')
        val stem = if (dot > 0) name.substring(0, dot) else name
        val extension = if (dot > 0) name.substring(dot) else ""
        var candidate = parent.resolve(name)
        var n = 1
        while (candidate.exists() ||
            (atTop && (candidate.name == DEFAULT_ROOT_ID || isProtected(base, candidate)))
        ) {
            candidate = parent.resolve("$stem ($n)$extension")
            n++
        }
        return candidate
    }

    private fun isProtected(base: File, file: File): Boolean =
        file.parentFile == base && fold(file.name) in PROTECTED_NAMES

    // [name] as storage that ignores case matches it: shared storage folds
    // case (so "DATA.SQLITE" or "data.ſqlite" is the database), may ignore
    // invisible characters, and SD cards drop trailing dots and spaces.
    private fun fold(name: String): String =
        Normalizer.normalize(name, Normalizer.Form.NFKC)
            .filter { Character.getType(it) != Character.FORMAT.toInt() }
            .uppercase(Locale.ROOT)
            .lowercase(Locale.ROOT)
            .trimEnd('.', ' ')

    // [file]'s id, or null when it isn't inside [base].
    private fun docIdOf(base: File, file: File): String? {
        if (file == base) return DEFAULT_ROOT_ID
        if (!file.path.startsWith(base.path + File.separator)) return null
        return file.path.substring(base.path.length + 1)
    }

    private fun childrenUri(base: File, folder: File?): Uri? {
        val context = context ?: return null
        val id = folder?.let { docIdOf(base, it) } ?: return null
        return DocumentsContract.buildChildDocumentsUri("${context.packageName}.documents", id)
    }

    private fun notifyChange(uri: Uri?) {
        if (uri == null) return
        context?.contentResolver?.notifyChange(uri, null)
    }

    private fun includeFile(result: MatrixCursor, base: File, file: File) {
        val row = result.newRow()
        row.add(Document.COLUMN_DOCUMENT_ID, docIdOf(base, file))
        row.add(Document.COLUMN_DISPLAY_NAME, file.name)
        row.add(Document.COLUMN_MIME_TYPE, getMimeType(file))

        val flags = when {
            file == base -> Document.FLAG_DIR_SUPPORTS_CREATE
            file.isDirectory -> Document.FLAG_DIR_SUPPORTS_CREATE or
                Document.FLAG_SUPPORTS_DELETE or Document.FLAG_SUPPORTS_RENAME
            isProtected(base, file) -> 0
            else -> Document.FLAG_SUPPORTS_WRITE or
                Document.FLAG_SUPPORTS_DELETE or Document.FLAG_SUPPORTS_RENAME
        }
        row.add(Document.COLUMN_FLAGS, flags)
        row.add(Document.COLUMN_SIZE, if (file.isDirectory) null else file.length())
        row.add(Document.COLUMN_LAST_MODIFIED, file.lastModified())
    }

    private fun getMimeType(file: File): String {
        if (file.isDirectory) return Document.MIME_TYPE_DIR

        // Manual extension extraction from filename (avoiding getFileExtensionFromUrl which fails with spaces)
        val name = file.name
        val lastDot = name.lastIndexOf('.')
        if (lastDot >= 0) {
            val extension = name.substring(lastDot + 1).lowercase()
            return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: "application/octet-stream"
        }
        return "application/octet-stream"
    }
}
